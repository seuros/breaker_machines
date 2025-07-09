# ActiveSupport::TestCase Testing Guide

## Overview

This guide provides patterns and helpers for testing circuit breakers with ActiveSupport::TestCase, commonly used in Rails applications. For general testing concepts applicable to all frameworks, refer to the main [Testing Guide](TESTING.md).

## Setup

### Basic Configuration

For more details on configuring BreakerMachines, see the [Configuration Guide](CONFIGURATION.md).

```ruby
# test/test_helper.rb
require 'breaker_machines'

class ActiveSupport::TestCase
  setup do
    # Configure for tests
    BreakerMachines.configure do |config|
      config.log_events = false
      config.default_storage = :memory
    end
  end

  teardown do
    # Reset all circuits after each test
    BreakerMachines.registry.clear
  end
end
```

### Test Helper Module

```ruby
# test/support/circuit_breaker_test_helper.rb
module CircuitBreakerTestHelper
  def force_circuit_open(circuit_name, service = nil)
    circuit = service ? service.circuit(circuit_name) : BreakerMachines.registry.get(circuit_name)
    threshold = circuit.config[:failure_threshold]

    threshold.times do
      begin
        circuit.wrap { raise StandardError, "Forced failure" }
      rescue StandardError
        # Expected
      end
    end
  end

  def force_circuit_closed(circuit_name, service = nil)
    circuit = service ? service.circuit(circuit_name) : BreakerMachines.registry.get(circuit_name)
    circuit.instance_variable_get(:@state_machine).close!
  end

  def force_circuit_half_open(circuit_name, service = nil)
    circuit = service ? service.circuit(circuit_name) : BreakerMachines.registry.get(circuit_name)
    circuit.instance_variable_get(:@state_machine).half_open!
  end

  def assert_circuit_open(circuit_name, service = nil)
    circuit = service ? service.circuit(circuit_name) : BreakerMachines.registry.get(circuit_name)
    assert_equal :open, circuit.state, "Expected circuit #{circuit_name} to be open"
  end

  def assert_circuit_closed(circuit_name, service = nil)
    circuit = service ? service.circuit(circuit_name) : BreakerMachines.registry.get(circuit_name)
    assert_equal :closed, circuit.state, "Expected circuit #{circuit_name} to be closed"
  end

  def assert_circuit_half_open(circuit_name, service = nil)
    circuit = service ? service.circuit(circuit_name) : BreakerMachines.registry.get(circuit_name)
    assert_equal :half_open, circuit.state, "Expected circuit #{circuit_name} to be half-open"
  end

  def circuit_failure_count(circuit_name, service = nil)
    circuit = service ? service.circuit(circuit_name) : BreakerMachines.registry.get(circuit_name)
    circuit.failure_count
  end
end

class ActiveSupport::TestCase
  include CircuitBreakerTestHelper
end
```

## Testing Circuit States

```ruby
class PaymentServiceTest < ActiveSupport::TestCase
  setup do
    @service = PaymentService.new
  end

  test "circuit opens after threshold failures" do
    # Force failures
    3.times do
      assert_raises StandardError do
        @service.circuit(:stripe).wrap { raise StandardError, "Payment failed" }
      end
    end

    # Circuit should be open
    assert_circuit_open(:stripe, @service)
  end

  test "returns fallback when circuit is open" do
    force_circuit_open(:stripe, @service)

    result = @service.charge(100)
    assert_equal({ error: "Payment queued for later" }, result)
  end

  test "circuit recovers after reset timeout" do
    force_circuit_open(:stripe, @service)

    travel_to 35.seconds.from_now do
      assert_circuit_half_open(:stripe, @service)

      # Mock successful call
      Stripe::Charge.stub :create, { success: true } do
        result = @service.charge(100)
        assert result[:success]
      end

      assert_circuit_closed(:stripe, @service)
    end
  end
end
```

## Testing Fallbacks

```ruby
class FallbackBehaviorTest < ActiveSupport::TestCase
  setup do
    @service_class = Class.new do
      include BreakerMachines::DSL

      circuit :api do
        threshold failures: 2, within: 60
        fallback { |error| "Fallback: #{error.class.name}" }
      end

      def call_api
        circuit(:api).wrap { yield }
      end
    end

    @service = @service_class.new
  end

  test "uses fallback when circuit is open" do
    force_circuit_open(:api, @service)

    result = @service.call_api { "should not execute" }
    assert_equal "Fallback: BreakerMachines::CircuitOpenError", result
  end

  test "passes original error to fallback" do
    # First failure - raises error
    assert_raises RuntimeError do
      @service.call_api { raise RuntimeError, "API Down" }
    end

    # Second failure opens circuit and uses fallback
    result = @service.call_api { raise RuntimeError, "API Down" }
    assert_equal "Fallback: RuntimeError", result
  end
end
```

## Testing Bulkheading

```ruby
class BulkheadProtectionTest < ActiveSupport::TestCase
  setup do
    @service_class = Class.new do
      include BreakerMachines::DSL

      circuit :limited do
        max_concurrent 2
        threshold failures: 3, within: 60
      end

      def process(&block)
        circuit(:limited).wrap(&block)
      end
    end

    @service = @service_class.new
  end

  test "limits concurrent requests" do
    active_threads = []
    results = Concurrent::Array.new

    # Fill bulkhead
    2.times do |i|
      active_threads << Thread.new do
        @service.process do
          sleep 0.1
          results << "success-#{i}"
        end
      end
    end

    # Wait for threads to start
    sleep 0.01

    # This should be rejected
    assert_raises BreakerMachines::CircuitBulkheadError do
      @service.process { "rejected" }
    end

    active_threads.each(&:join)
    assert_equal 2, results.size
  end

  test "bulkhead rejections don't count as circuit failures" do
    threads = []

    # Create 3 threads (one will be rejected)
    3.times do
      threads << Thread.new do
        @service.process { sleep 0.1 } rescue nil
      end
    end

    threads.each(&:join)

    # Circuit should still be closed
    assert_circuit_closed(:limited, @service)
    assert_equal 0, circuit_failure_count(:limited, @service)
  end
end
```

## Testing Hedged Requests

```ruby
class HedgedRequestsTest < ActiveSupport::TestCase
  setup do
    @service_class = Class.new do
      include BreakerMachines::DSL

      circuit :fast_api do
        hedged do
          delay 50
          max_requests 3
        end
      end

      def fetch_data
        circuit(:fast_api).wrap { make_request }
      end

      def make_request
        # Stubbed in tests
      end
    end

    @service = @service_class.new
    @call_count = 0
  end

  test "returns first successful response" do
    response_times = [0.1, 0.02, 0.15]  # Second call is fastest

    @service.stub :make_request, -> {
      delay = response_times[@call_count]
      result = "response-#{@call_count}"
      @call_count += 1
      sleep delay
      result
    } do
      result = @service.fetch_data

      # Should get a response
      assert_match(/response-\d/, result)
      # Multiple requests should have been made
      assert_operator @call_count, :>=, 2
    end
  end
end
```

## Testing with Time Helpers

```ruby
class TimeBasedCircuitTest < ActiveSupport::TestCase
  setup do
    @service = TimeBasedService.new
  end

  test "circuit transitions through states over time" do
    # Force circuit open
    force_circuit_open(:timed, @service)
    assert_circuit_open(:timed, @service)

    # Still open after 29 seconds
    travel_to 29.seconds.from_now do
      assert_circuit_open(:timed, @service)
    end

    # Half-open after 30 seconds
    travel_to 31.seconds.from_now do
      assert_circuit_half_open(:timed, @service)
    end
  end

  test "failure window expires" do
    # Record 2 failures
    2.times do
      @service.circuit(:windowed).wrap { raise "Error" } rescue nil
    end

    # Travel past the window
    travel_to 2.minutes.from_now do
      # One more failure shouldn't open circuit
      @service.circuit(:windowed).wrap { raise "Error" } rescue nil
      assert_circuit_closed(:windowed, @service)
    end
  end
end
```

## Testing Storage Backends

For a deeper understanding of storage options and their implications, refer to the [Persistence Options](PERSISTENCE.md) guide.

```ruby
class StorageBackendTest < ActiveSupport::TestCase
  test "shares state with Redis storage" do
    redis = MockRedis.new

    with_storage(:cache, cache_store: redis) do
      service1 = MyService.new
      service2 = MyService.new

      # Open circuit in first instance
      force_circuit_open(:shared, service1)

      # Second instance should see open state
      assert_circuit_open(:shared, service2)
    end
  end

  private

  def with_storage(type, options = {})
    original = BreakerMachines.config.default_storage
    BreakerMachines.config.default_storage = [type, options]
    yield
  ensure
    BreakerMachines.config.default_storage = original
  end
end
```

## Testing Callbacks

```ruby
class CircuitCallbacksTest < ActiveSupport::TestCase
  setup do
    @events = []

    @service_class = Class.new do
      include BreakerMachines::DSL

      circuit :monitored do
        threshold failures: 2, within: 60

        on_open { @events << :opened }
        on_close { @events << :closed }
        on_half_open { @events << :half_opened }
        on_reject { @events << :rejected }
      end
    end

    @service = @service_class.new
    @service.instance_variable_set(:@events, @events)
  end

  test "triggers callbacks on state changes" do
    # Trigger open
    2.times do
      @service.circuit(:monitored).wrap { raise "Error" } rescue nil
    end

    assert_includes @events, :opened

    # Trigger reject
    @service.circuit(:monitored).wrap { "rejected" } rescue nil
    assert_includes @events, :rejected

    # Reset for half-open test
    @events.clear

    # Trigger half-open and close
    travel_to 61.seconds.from_now do
      @service.circuit(:monitored).wrap { "success" }
      assert_includes @events, :closed
    end
  end
end
```

## Custom Assertions

```ruby
# test/support/circuit_assertions.rb
module CircuitAssertions
  def assert_uses_fallback(expected_fallback, circuit_name, service)
    force_circuit_open(circuit_name, service)
    result = service.circuit(circuit_name).wrap { "should not run" }
    assert_equal expected_fallback, result,
      "Expected fallback #{expected_fallback.inspect}, got #{result.inspect}"
  end

  def assert_circuit_trips_after(failure_count, circuit_name, service)
    (failure_count - 1).times do
      service.circuit(circuit_name).wrap { raise "Error" } rescue nil
    end
    assert_circuit_closed(circuit_name, service)

    # One more failure should trip it
    service.circuit(circuit_name).wrap { raise "Error" } rescue nil
    assert_circuit_open(circuit_name, service)
  end

  def assert_concurrent_limit(limit, circuit_name, service)
    threads = []
    counter = Concurrent::AtomicFixnum.new(0)

    (limit + 1).times do
      threads << Thread.new do
        service.circuit(circuit_name).wrap do
          counter.increment
          sleep 0.1
        end rescue nil
      end
    end

    threads.each(&:join)
    assert_equal limit, counter.value,
      "Expected #{limit} concurrent executions, got #{counter.value}"
  end
end

class ActiveSupport::TestCase
  include CircuitAssertions
end
```

## Performance Testing

For more comprehensive performance monitoring and observability, refer to the [Observability Guide](OBSERVABILITY.md).

```ruby
class CircuitPerformanceTest < ActiveSupport::TestCase
  setup do
    @service = PerformanceService.new
  end

  test "handles high throughput" do
    iterations = 10_000

    elapsed = Benchmark.realtime do
      iterations.times do
        @service.circuit(:performance).wrap { "success" }
      end
    end

    ops_per_second = iterations / elapsed
    assert_operator ops_per_second, :>, 50_000,
      "Expected > 50k ops/sec, got #{ops_per_second}"
  end

  test "minimal overhead when closed" do
    baseline = Benchmark.realtime do
      10_000.times { "direct call" }
    end

    circuit_time = Benchmark.realtime do
      10_000.times do
        @service.circuit(:performance).wrap { "wrapped call" }
      end
    end

    overhead_percent = ((circuit_time - baseline) / baseline) * 100
    assert_operator overhead_percent, :<, 10,
      "Circuit overhead was #{overhead_percent}%, expected < 10%"
  end
end
```

## Integration Testing

```ruby
class FullIntegrationTest < ActionDispatch::IntegrationTest
  test "handles cascading failures gracefully" do
    # Simulate API failure
    stub_request(:get, "https://api.example.com/data")
      .to_timeout
      .times(3)
      .then
      .to_return(body: '{"data": "recovered"}')

    # First requests fail and open circuit
    3.times do
      get "/api/data"
      assert_response :service_unavailable
    end

    # Circuit open, should get fallback
    get "/api/data"
    assert_response :success
    assert_equal "cached_data", JSON.parse(response.body)["data"]

    # After reset timeout, circuit recovers
    travel_to 1.minute.from_now do
      get "/api/data"
      assert_response :success
      assert_equal "recovered", JSON.parse(response.body)["data"]
    end
  end
end
```

## Test Helpers for Rails

```ruby
# test/test_helper.rb
class ActionDispatch::IntegrationTest
  def assert_circuit_degraded(circuit_name)
    circuit = BreakerMachines.registry.get(circuit_name)
    assert [:open, :half_open].include?(circuit.state),
      "Expected circuit to be degraded (open/half-open), but was #{circuit.state}"
  end

  def wait_for_circuit_recovery(circuit_name)
    circuit = BreakerMachines.registry.get(circuit_name)
    reset_time = circuit.config[:reset_timeout]
    travel_to (reset_time + 1.second).from_now
  end
end
```

## Best Practices

1. **Use `travel_to` for time-based tests** - More reliable than sleep
2. **Clear state in teardown** - Prevent test pollution
3. **Use stubs for external services** - Faster and more reliable
4. **Test both success and failure paths** - Ensure proper degradation
5. **Use concurrent testing carefully** - Thread timing can be tricky
6. **Assert on specific states** - Don't just check "not closed"

## Next Steps

- See [RSpec Testing Guide](TESTING_RSPEC.md) for RSpec patterns
- Review [Rails Integration](RAILS_INTEGRATION.md) for Rails-specific testing
- Explore [Advanced Patterns](ADVANCED_PATTERNS.md) for complex scenarios
- Learn about [Observability](OBSERVABILITY.md) for monitoring your circuits
- Understand [Configuration Options](CONFIGURATION.md) for test setup