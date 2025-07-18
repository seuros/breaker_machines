# Async Mode Documentation

## Overview

BreakerMachines offers two levels of async support:
1. **fiber_safe mode** - For modern Ruby applications using Fiber-based servers like Falcon
2. **AsyncCircuit class** - Leveraging state_machines' async: true parameter for thread-safe concurrent operations

**Important**: The `async` gem is completely optional. BreakerMachines works perfectly without it. You only need `async` if you want to use `fiber_safe` mode with Falcon or similar async frameworks.

## Why Fiber Support?

Traditional circuit breakers block the entire thread during I/O operations. In a Fiber-based server, this freezes your entire event loop. Not ideal when you're trying to handle 10,000 concurrent requests on a single thread.

With `fiber_safe` mode, BreakerMachines becomes a good citizen in your async environment:
- **Non-blocking operations** that yield to the scheduler
- **Safe, cooperative timeouts** using Async::Task
- **Natural async/await integration**
- **No thread blocking** means better concurrency

## Installation

Add the `async` gem to your Gemfile (only if you want fiber_safe mode):

```ruby
gem 'async' # Only required for fiber_safe mode
```

## Configuration

For general configuration options, including default thresholds, reset times, and logging, refer to the [Configuration Guide](CONFIGURATION.md).

### Global Configuration

```ruby
BreakerMachines.configure do |config|
  config.fiber_safe = true
end
```

### Per-Circuit Configuration

```ruby
circuit :async_api do
  fiber_safe true
  threshold failures: 3, within: 60
  timeout 5  # Safe cooperative timeout!
  reset_after 30
end
```

## Cooperative Timeouts

In `fiber_safe` mode, timeouts are implemented using `Async::Task.current.with_timeout`, which is safe and cooperative:

```ruby
circuit :slow_api do
  fiber_safe true
  timeout 3  # Uses Async::Task timeout
  threshold failures: 2, within: 30
end

# This will timeout safely after 3 seconds without corruption
circuit(:slow_api).wrap do
  HTTP.get('https://slow-api.example.com/endpoint')
end
```

Unlike Ruby's dangerous `Timeout.timeout`, cooperative timeouts:
- Never corrupt state
- Clean up resources properly
- Work naturally with async I/O
- Don't kill threads unexpectedly

## Examples

### AI Service with Safe Timeouts

```ruby
class AIService
  include BreakerMachines::DSL

  circuit :gpt4 do
    fiber_safe true
    threshold failures: 2, within: 30
    timeout 10  # Cooperative timeout - won't corrupt state!

    fallback do |error|
      # Fallback can also be async
      Async do
        # Try a cheaper model
        openai.completions(model: 'gpt-3.5-turbo', prompt: @prompt)
      end
    end
  end

  def generate_response(prompt)
    @prompt = prompt
    circuit(:gpt4).wrap do
      # Returns an Async::Task in Falcon
      Async::HTTP::Internet.new.post(
        'https://api.openai.com/v1/completions',
        headers: { 'Authorization' => "Bearer #{api_key}" },
        body: { model: 'gpt-4', prompt: prompt }.to_json
      )
    end
  end

  private

  def api_key
    ENV['OPENAI_API_KEY']
  end

  def openai
    @openai ||= OpenAI::Client.new(api_key: api_key)
  end
end
```

### Async HTTP Client

```ruby
class AsyncAPIClient
  include BreakerMachines::DSL

  circuit :external_api do
    fiber_safe true
    threshold failures: 5, within: 2.minutes
    timeout 5

    fallback do
      { status: 'degraded', data: cached_response }
    end
  end

  def fetch_data(endpoint)
    circuit(:external_api).wrap do
      Async do
        internet = Async::HTTP::Internet.new
        response = internet.get("https://api.example.com/#{endpoint}")
        JSON.parse(response.read)
      end
    end
  end

  private

  def cached_response
    # Your cache implementation
    Rails.cache.read('api:fallback:data') || {}
  end
end
```

### Database Operations

```ruby
class AsyncDatabaseService
  include BreakerMachines::DSL

  circuit :postgres do
    fiber_safe true
    threshold failures: 3, within: 30.seconds
    timeout 5  # Database query timeout

    fallback do
      # Return cached data during outage
      fetch_from_cache
    end
  end

  def find_user(id)
    circuit(:postgres).wrap do
      Async do
        # Using async-postgres or similar
        DB.async_exec("SELECT * FROM users WHERE id = $1", [id]).first
      end
    end
  end

  private

  def fetch_from_cache
    # Your cache implementation
  end
end
```

## Async Storage Backends

For true non-blocking operation, use async-compatible storage backends. See [Async Storage Examples](ASYNC_STORAGE_EXAMPLES.md) for detailed implementations of Redis, PostgreSQL, and other async storage backends. This is crucial for maintaining a fully asynchronous application.

## Hedged Requests in Async Mode

When both `fiber_safe` and hedged requests are enabled, requests run concurrently using fibers:

```ruby
circuit :fast_api do
  fiber_safe true
  threshold failures: 3, within: 1.minute

  hedged do
    delay 100        # Start backup request after 100ms
    max_requests 3   # Up to 3 concurrent requests
  end
end

# If the first request is slow, additional requests start automatically
# First successful response wins, others are cancelled
result = circuit(:fast_api).wrap do
  fetch_from_slow_api
end
```

## AsyncCircuit Class

The `AsyncCircuit` class provides thread-safe state transitions using state_machines' async support:

### Basic AsyncCircuit Usage

```ruby
# Create an async circuit
async_circuit = BreakerMachines::AsyncCircuit.new('payment_api', {
  failure_threshold: 5,
  reset_timeout: 30.seconds,
  timeout: 10
})

# Use it like a regular circuit
result = async_circuit.call do
  PaymentAPI.process(order)
end

# Or use async-specific methods (requires async gem)
if defined?(Async)
  Async do
    task = async_circuit.call_async do
      PaymentAPI.process_async(order)
    end
    result = task.wait
  end
end
```

### Understanding the async: true Parameter

The AsyncCircuit leverages state_machines' `async: true` parameter, which automatically wraps all state transitions in mutex synchronization:

```ruby
# Under the hood, AsyncCircuit uses:
state_machine :status, initial: :closed, async: true do
  # All transitions are automatically thread-safe
end
```

This parameter:
- Adds mutex protection to all state transitions
- Ensures thread-safe callback execution
- Prevents race conditions in concurrent environments
- Works seamlessly with JRuby and TruffleRuby's threading models

### Thread-Safe State Transitions

AsyncCircuit automatically provides mutex-protected state transitions:

```ruby
# Multiple threads can safely transition states
threads = 10.times.map do
  Thread.new do
    100.times do
      begin
        async_circuit.call { perform_operation }
      rescue => e
        # Circuit handles concurrent failures safely
      end
    end
  end
end

threads.each(&:join)
```

### Using with Circuit Groups

```ruby
# Enable async mode for all circuits in a group
async_services = BreakerMachines::CircuitGroup.new('services', 
                                                   async_mode: true)

async_services.circuit :database do
  threshold failures: 3
  timeout 5
end

async_services.circuit :cache do
  threshold failures: 5
  timeout 2
end

# All circuits in the group are AsyncCircuit instances
async_services[:database].class # => BreakerMachines::AsyncCircuit
```

## Integration with Falcon

BreakerMachines works seamlessly with Falcon server:

```ruby
# config.ru
require 'falcon'
require 'breaker_machines'

BreakerMachines.configure do |config|
  config.fiber_safe = true
  config.log_events = true
end

run MyApp
```

In your application:

```ruby
class MyApp < Roda
  plugin :circuit_breaker

  route do |r|
    r.get "api" do
      # Use fiber_safe circuit for Falcon
      circuit(:external_api).wrap do
        # This won't block the event loop
        fetch_external_data
      end
    end

    r.get "async_api" do
      # Or use AsyncCircuit for thread-safe operations
      async_circuit.call do
        fetch_concurrent_data
      end
    end
  end
end
```

## Testing Async Circuits

```ruby
require 'async/rspec'

RSpec.describe AsyncService do
  include Async::RSpec::Reactor

  let(:service) { AsyncService.new }

  it "handles circuit breaker in async context" do |reactor|
    # Force circuit open
    3.times do
      expect {
        service.circuit(:api).wrap { raise "Error" }
      }.to raise_error("Error")
    end

    # Circuit should be open
    expect(service.circuit(:api)).to be_open

    # Should return fallback without blocking
    result = service.fetch_data
    expect(result).to eq({ status: 'degraded' })
  end

  it "respects cooperative timeout" do |reactor|
    service.circuit(:slow_api).wrap do
      reactor.sleep(10) # Will timeout after 3 seconds
    end
  rescue BreakerMachines::CircuitTimeoutError
    # Expected timeout
  end
end
```

## Performance Considerations

For comprehensive performance monitoring and observability in async mode, refer to the [Observability Guide](OBSERVABILITY.md).

### Fiber Pool Size

```ruby
# Falcon automatically manages fiber pool
# But you can tune circuit breaker concurrency:

circuit :high_throughput do
  fiber_safe true
  max_concurrent 100  # Limit concurrent fibers
  threshold failures: 10, within: 30.seconds
end
```

### Memory Usage

Fibers are lightweight but not free. Monitor memory usage:

```ruby
circuit :memory_aware do
  fiber_safe true
  before_call do
    if GC.stat[:heap_live_slots] > 1_000_000
      GC.start
    end
  end
end
```

## Common Pitfalls

### Don't Block the Reactor

```ruby
# ❌ BAD: Blocks the reactor
circuit(:api).wrap do
  sleep(1)  # This blocks everything!
  fetch_data
end

# ✅ GOOD: Yields to the reactor
circuit(:api).wrap do
  Async::Task.current.sleep(1)  # Non-blocking
  fetch_data
end
```

### Thread-Local Variables

```ruby
# ❌ BAD: Thread locals don't work with fibers
Thread.current[:user_id] = 123

# ✅ GOOD: Use Fiber locals
Fiber.current[:user_id] = 123
```

## Debugging

For more advanced debugging techniques and how to integrate with your monitoring systems, consult the [Observability Guide](OBSERVABILITY.md).

Enable detailed logging for async operations:

```ruby
BreakerMachines.configure do |config|
  config.fiber_safe = true
  config.log_events = true
  config.logger = Logger.new($stdout).tap do |logger|
    logger.level = Logger::DEBUG
  end
end

# Watch fiber switching
Async.logger.level = Logger::DEBUG
```

## Best Practices

1. **Use fiber_safe for I/O operations** - Database queries, HTTP calls, Redis operations
2. **Keep CPU-bound work outside circuits** - Or use Ractors for parallel processing
3. **Monitor fiber count** - Too many concurrent fibers can cause memory issues
4. **Test timeout behavior** - Ensure your timeouts work as expected
5. **Use async storage** - For maximum performance, use async-compatible storage backends

## Platform Support

### JRuby Considerations
- AsyncCircuit works seamlessly on JRuby with thread-based concurrency
- The `async: true` parameter leverages JRuby's efficient thread management
- Fiber-safe mode requires the `async` gem's JRuby fiber implementation
- Performance is excellent due to JVM's mature threading model

### TruffleRuby Support
- Full compatibility with both fiber_safe mode and AsyncCircuit
- TruffleRuby's advanced JIT compilation optimizes state machine transitions
- The `async: true` parameter benefits from TruffleRuby's low-overhead locking
- Consider using TruffleRuby for CPU-intensive circuit breaker workloads

## Next Steps

- Review [Testing Patterns](TESTING.md) for async circuit testing
- Explore [Rails Integration](RAILS_INTEGRATION.md) with Falcon
- Learn about [Performance Monitoring and Observability](OBSERVABILITY.md) in async mode
- Dive deeper into [Async Storage Examples](ASYNC_STORAGE_EXAMPLES.md) for distributed async state