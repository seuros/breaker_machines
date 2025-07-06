# Async Mode Documentation

## Overview

BreakerMachines offers optional `fiber_safe` mode for modern Ruby applications using Fiber-based servers like Falcon. This mode enables non-blocking operations, cooperative timeouts, and seamless integration with async/await patterns.

**Important**: The `async` gem is completely optional. BreakerMachines works perfectly without it. You only need `async` if you want to use `fiber_safe` mode.

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
circuit :async_api, fiber_safe: true do
  threshold failures: 3, within: 60
  timeout 5  # Safe cooperative timeout!
  reset_after 30
end
```

## Cooperative Timeouts

In `fiber_safe` mode, timeouts are implemented using `Async::Task.current.with_timeout`, which is safe and cooperative:

```ruby
circuit :slow_api, fiber_safe: true do
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

  circuit :gpt4, fiber_safe: true do
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

  circuit :external_api, fiber_safe: true do
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

  circuit :postgres, fiber_safe: true do
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
circuit :fast_api, fiber_safe: true do
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
      circuit(:external_api).wrap do
        # This won't block the event loop
        fetch_external_data
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

circuit :high_throughput, fiber_safe: true do
  max_concurrent 100  # Limit concurrent fibers
  threshold failures: 10, within: 30.seconds
end
```

### Memory Usage

Fibers are lightweight but not free. Monitor memory usage:

```ruby
circuit :memory_aware, fiber_safe: true do
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

## Next Steps

- Review [Testing Patterns](TESTING.md) for async circuit testing
- Explore [Rails Integration](RAILS_INTEGRATION.md) with Falcon
- Learn about [Performance Monitoring and Observability](OBSERVABILITY.md) in async mode
- Dive deeper into [Async Storage Examples](ASYNC_STORAGE_EXAMPLES.md) for distributed async state