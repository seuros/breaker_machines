# Testing Guide

## Overview

Testing circuit breakers requires special considerations for timing, state management, and failure scenarios. We provide separate guides for different testing frameworks:

- [RSpec Testing Guide](TESTING_RSPEC.md) - For RSpec users
- [ActiveSupport::TestCase Testing Guide](TESTING_ACTIVESUPPORT.md) - For Rails minitest users

This guide covers general testing concepts applicable to both frameworks.

## Basic Testing Patterns

### Testing Circuit States

```ruby
RSpec.describe PaymentService do
  let(:service) { PaymentService.new }

  it "handles circuit open state" do
    # Force circuit open
    3.times do
      expect {
        service.circuit(:stripe).wrap { raise "Payment failed" }
      }.to raise_error("Payment failed")
    end

    # Circuit should now be open
    expect(service.circuit(:stripe)).to be_open

    # Should return fallback
    result = service.charge(100)
    expect(result).to eq({ error: "Payment queued for later" })
  end

  it "recovers after reset timeout" do
    # Open the circuit
    force_circuit_open(:stripe)

    # Travel past reset timeout
    travel_to(35.seconds.from_now) do
      # Circuit should be half-open
      expect(service.circuit(:stripe)).to be_half_open

      # Successful call should close circuit
      allow(Stripe::Charge).to receive(:create).and_return(success: true)
      result = service.charge(100)

      expect(service.circuit(:stripe)).to be_closed
    end
  end
end
```

## Test Helpers

### CircuitBreakerTestHelper Module

```ruby
# spec/support/circuit_breaker_test_helper.rb
module CircuitBreakerTestHelper
  def force_circuit_open(circuit_name)
    circuit = described_class.circuit(circuit_name)
    threshold = circuit.config[:failure_threshold]

    threshold.times do
      begin
        circuit.wrap { raise StandardError, "Forced failure" }
      rescue StandardError
        # Expected
      end
    end
  end

  def force_circuit_closed(circuit_name)
    circuit = described_class.circuit(circuit_name)
    circuit.instance_variable_get(:@state_machine).close!
  end

  def force_circuit_half_open(circuit_name)
    circuit = described_class.circuit(circuit_name)
    circuit.instance_variable_get(:@state_machine).half_open!
  end

  def with_circuit_state(circuit_name, state)
    original_state = described_class.circuit(circuit_name).state
    send("force_circuit_#{state}", circuit_name)
    yield
  ensure
    force_circuit_state(circuit_name, original_state)
  end

  def circuit_failure_count(circuit_name)
    described_class.circuit(circuit_name).failure_count
  end

  def reset_all_circuits
    BreakerMachines.registry.all.each do |name, circuit|
      circuit.reset!
    end
  end
end

RSpec.configure do |config|
  config.include CircuitBreakerTestHelper

  config.after(:each) do
    reset_all_circuits
  end
end
```

## Testing Specific Features

### Testing Fallbacks

```ruby
describe "fallback behavior" do
  it "uses static fallback" do
    service = Class.new do
      include BreakerMachines::DSL

      circuit :api do
        fallback { "default response" }
      end
    end.new

    force_circuit_open(:api)
    result = service.circuit(:api).wrap { "should not execute" }
    expect(result).to eq("default response")
  end

  it "passes error to fallback block" do
    service = Class.new do
      include BreakerMachines::DSL

      circuit :api do
        fallback { |error| "Error: #{error.message}" }
      end
    end.new

    # Trigger failure
    3.times do
      service.circuit(:api).wrap { raise "API Error" } rescue nil
    end

    result = service.circuit(:api).wrap { "should not execute" }
    expect(result).to eq("Error: BreakerMachines::CircuitOpenError")
  end
end
```

### Testing Bulkheading

```ruby
describe "bulkhead limits" do
  let(:service) do
    Class.new do
      include BreakerMachines::DSL

      circuit :limited do
        max_concurrent 2
        threshold failures: 3, within: 60
      end
    end.new
  end

  it "rejects requests over limit" do
    threads = []
    results = Concurrent::Array.new

    # Fill up the bulkhead
    2.times do
      threads << Thread.new do
        service.circuit(:limited).wrap do
          sleep 0.1
          results << "success"
        end
      end
    end

    # Wait for threads to start
    sleep 0.01

    # This should be rejected
    expect {
      service.circuit(:limited).wrap { "rejected" }
    }.to raise_error(BreakerMachines::CircuitBulkheadError)

    threads.each(&:join)
    expect(results.size).to eq(2)
  end

  it "doesn't count bulkhead rejections as failures" do
    # Fill bulkhead and get rejected
    2.times do
      Thread.new { service.circuit(:limited).wrap { sleep 0.1 } }
    end
    sleep 0.01

    # Get rejected
    expect {
      service.circuit(:limited).wrap { "rejected" }
    }.to raise_error(BreakerMachines::CircuitBulkheadError)

    # Circuit should still be closed
    expect(service.circuit(:limited)).to be_closed
    expect(circuit_failure_count(:limited)).to eq(0)
  end
end
```

### Testing Hedged Requests

```ruby
describe "hedged requests" do
  let(:service) do
    Class.new do
      include BreakerMachines::DSL

      circuit :hedged_api do
        hedged do
          delay 50
          max_requests 3
        end
        threshold failures: 3, within: 60
      end
    end.new
  end

  it "returns fastest response" do
    call_times = Concurrent::Array.new

    # Simulate varying response times
    allow(service).to receive(:make_request) do
      start_time = Time.now
      sleep [0.1, 0.05, 0.02].sample
      call_times << Time.now - start_time
      "response"
    end

    result = service.circuit(:hedged_api).wrap { service.make_request }

    expect(result).to eq("response")
    # Should have made multiple attempts
    expect(call_times.size).to be >= 2
  end
end
```

## Testing Async Circuits

For a deeper understanding of BreakerMachines' asynchronous capabilities, refer to the [Async Mode](ASYNC.md) documentation.

```ruby
require 'async/rspec'

RSpec.describe AsyncService do
  include Async::RSpec::Reactor

  let(:service) { AsyncService.new }

  it "handles async circuit operations" do |reactor|
    # Test within reactor context
    3.times do
      expect {
        service.circuit(:async_api).wrap do
          raise "Async failure"
        end
      }.to raise_error("Async failure")
    end

    expect(service.circuit(:async_api)).to be_open

    # Async fallback
    result = service.circuit(:async_api).wrap { "should not run" }
    expect(result).to eq("async fallback")
  end

  it "respects cooperative timeout" do |reactor|
    start = Time.now

    expect {
      service.circuit(:slow_api).wrap do
        reactor.sleep(10)  # Should timeout after 3 seconds
      end
    }.to raise_error(BreakerMachines::CircuitTimeoutError)

    expect(Time.now - start).to be_within(0.1).of(3)
  end
end
```

## Testing Storage Backends

For more details on configuring and implementing various storage backends, see the [Persistence Options](PERSISTENCE.md) guide.

```ruby
describe "storage persistence" do
  context "with Redis storage" do
    let(:redis) { MockRedis.new }
    let(:service) do
      Class.new do
        include BreakerMachines::DSL

        circuit :persistent do
          storage :cache, cache_store: redis
          threshold failures: 3, within: 60
        end
      end.new
    end

    it "persists state across instances" do
      # Open circuit in first instance
      force_circuit_open(:persistent)

      # Create new instance with same storage
      new_service = service.class.new

      # Should see open state
      expect(new_service.circuit(:persistent)).to be_open
    end

    it "shares failure counts" do
      # Record failures in multiple instances
      service1 = service.class.new
      service2 = service.class.new

      # Each records one failure
      service1.circuit(:persistent).wrap { raise "Error" } rescue nil
      service2.circuit(:persistent).wrap { raise "Error" } rescue nil

      # Both should see 2 failures
      expect(service1.circuit(:persistent).failure_count).to eq(2)
      expect(service2.circuit(:persistent).failure_count).to eq(2)
    end
  end
end
```

## Testing Callbacks

```ruby
describe "circuit callbacks" do
  let(:events) { [] }
  let(:service) do
    captured_events = events

    Class.new do
      include BreakerMachines::DSL

      circuit :monitored do
        threshold failures: 2, within: 60

        on_open { captured_events << :opened }
        on_close { captured_events << :closed }
        on_half_open { captured_events << :half_opened }
        on_reject { captured_events << :rejected }
      end
    end.new
  end

  it "triggers callbacks on state changes" do
    # Trigger open
    2.times do
      service.circuit(:monitored).wrap { raise "Error" } rescue nil
    end

    expect(events).to eq([:opened])

    # Trigger reject
    service.circuit(:monitored).wrap { "rejected" } rescue nil
    expect(events).to eq([:opened, :rejected])

    # Trigger half-open
    travel_to(61.seconds.from_now) do
      allow(service.circuit(:monitored)).to receive(:state).and_return(:half_open)
      events.clear

      # Successful call closes circuit
      service.circuit(:monitored).wrap { "success" }
      expect(events).to include(:closed)
    end
  end
end
```

## Performance Testing

```ruby
describe "circuit performance" do
  let(:service) do
    Class.new do
      include BreakerMachines::DSL

      circuit :performance_test do
        threshold failures: 100, within: 60
      end
    end.new
  end

  it "handles high throughput" do
    iterations = 10_000
    start_time = Time.now

    iterations.times do
      service.circuit(:performance_test).wrap { "success" }
    end

    duration = Time.now - start_time
    ops_per_second = iterations / duration

    expect(ops_per_second).to be > 50_000  # Should handle 50k+ ops/sec
  end

  it "has minimal overhead when closed" do
    baseline_time = Benchmark.realtime do
      10_000.times { "direct call" }
    end

    circuit_time = Benchmark.realtime do
      10_000.times do
        service.circuit(:performance_test).wrap { "wrapped call" }
      end
    end

    overhead_percent = ((circuit_time - baseline_time) / baseline_time) * 100
    expect(overhead_percent).to be < 10  # Less than 10% overhead
  end
end
```

## Testing Anti-Patterns

### Don't Test Implementation Details

```ruby
# ❌ BAD: Testing internal state machine
it "transitions through states correctly" do
  state_machine = service.circuit(:api).instance_variable_get(:@state_machine)
  expect(state_machine.current_state).to eq(:closed)
end

# ✅ GOOD: Test observable behavior
it "opens after threshold failures" do
  3.times do
    service.circuit(:api).wrap { raise "Error" } rescue nil
  end

  expect(service.circuit(:api)).to be_open
end
```

### Don't Rely on Timing

```ruby
# ❌ BAD: Brittle timing-dependent test
it "resets after exactly 30 seconds" do
  force_circuit_open(:api)
  sleep 30
  expect(service.circuit(:api)).to be_half_open
end

# ✅ GOOD: Use time helpers
it "resets after timeout period" do
  force_circuit_open(:api)
  travel_to(31.seconds.from_now) do
    expect(service.circuit(:api)).to be_half_open
  end
end
```

## Test Configuration

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.before(:suite) do
    # Disable event logging in tests
    BreakerMachines.configure do |c|
      c.log_events = false
      c.default_storage = :memory  # Always use memory in tests
    end
  end

  config.around(:each, :async) do |example|
    Async do
      example.run
    end
  end
end
```

## Best Practices

1. **Reset state between tests** - Always clean up circuit states
2. **Use time helpers** - Don't rely on sleep or real time
3. **Test edge cases** - Concurrent access, storage failures, etc.
4. **Mock external dependencies** - Don't make real API calls
5. **Test both success and failure paths** - Ensure fallbacks work
6. **Verify metrics and monitoring** - Test your observability

## Next Steps

- See [RSpec Testing Guide](TESTING_RSPEC.md) for RSpec-specific patterns
- See [ActiveSupport Testing Guide](TESTING_ACTIVESUPPORT.md) for Rails testing
- Review [Rails Integration](RAILS_INTEGRATION.md) for Rails-specific testing
- Learn about [Observability](OBSERVABILITY.md) testing
- Explore [Advanced Patterns](ADVANCED_PATTERNS.md) for complex test scenarios
- Understand [Configuration Options](CONFIGURATION.md) for test setup