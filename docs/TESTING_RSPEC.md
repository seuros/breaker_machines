# RSpec Testing Guide

## Overview

This guide provides comprehensive patterns and helpers for testing circuit breakers with RSpec. For general testing concepts applicable to all frameworks, refer to the main [Testing Guide](TESTING.md).

## Setup

### Basic Configuration

For more details on configuring BreakerMachines, see the [Configuration Guide](CONFIGURATION.md).

```ruby
# spec/spec_helper.rb
require 'breaker_machines'

RSpec.configure do |config|
  config.before(:suite) do
    # Disable event logging in tests
    BreakerMachines.configure do |c|
      c.log_events = false
      c.default_storage = :memory  # Always use memory in tests
    end
  end

  config.after(:each) do
    # Reset all circuits between tests
    BreakerMachines.registry.clear
  end
end
```

### Test Helper Module

```ruby
# spec/support/circuit_breaker_helper.rb
module CircuitBreakerHelper
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
  config.include CircuitBreakerHelper
end
```

## Testing Circuit States

```ruby
RSpec.describe PaymentService do
  let(:service) { PaymentService.new }

  describe "circuit breaker behavior" do
    it "opens circuit after threshold failures" do
      # Force failures
      3.times do
        expect {
          service.circuit(:stripe).wrap { raise "Payment failed" }
        }.to raise_error("Payment failed")
      end

      # Circuit should be open
      expect(service.circuit(:stripe)).to be_open
    end

    it "returns fallback when circuit is open" do
      force_circuit_open(:stripe)

      result = service.charge(100)
      expect(result).to eq({ error: "Payment queued for later" })
    end

    it "recovers after reset timeout" do
      force_circuit_open(:stripe)

      travel_to(35.seconds.from_now) do
        expect(service.circuit(:stripe)).to be_half_open

        # Successful call closes circuit
        allow(Stripe::Charge).to receive(:create).and_return(success: true)
        result = service.charge(100)

        expect(service.circuit(:stripe)).to be_closed
      end
    end
  end
end
```

## Testing Fallbacks

```ruby
RSpec.describe "fallback behavior" do
  let(:service_class) do
    Class.new do
      include BreakerMachines::DSL

      circuit :api do
        threshold failures: 2, within: 60
        fallback { |error| "Fallback: #{error.class.name}" }
      end

      def call_api
        circuit(:api).wrap { yield }
      end
    end
  end

  let(:service) { service_class.new }

  it "uses fallback when circuit is open" do
    force_circuit_open(:api)

    result = service.call_api { "should not execute" }
    expect(result).to eq("Fallback: BreakerMachines::CircuitOpenError")
  end

  it "passes original error to fallback on failure" do
    # First failure
    expect {
      service.call_api { raise CustomError, "API Down" }
    }.to raise_error(CustomError)

    # Second failure opens circuit
    result = service.call_api { raise CustomError, "API Down" }
    expect(result).to eq("Fallback: CustomError")
  end
end
```

## Testing Bulkheading

```ruby
RSpec.describe "bulkhead protection" do
  let(:service_class) do
    Class.new do
      include BreakerMachines::DSL

      circuit :limited do
        max_concurrent 2
        threshold failures: 3, within: 60
      end

      def process
        circuit(:limited).wrap { yield }
      end
    end
  end

  let(:service) { service_class.new }

  it "limits concurrent requests" do
    active_threads = []
    rejected = false

    # Fill bulkhead
    2.times do
      active_threads << Thread.new do
        service.process { sleep 0.1 }
      end
    end

    # Wait for threads to start
    sleep 0.01

    # This should be rejected
    expect {
      service.process { "rejected" }
    }.to raise_error(BreakerMachines::CircuitBulkheadError)

    active_threads.each(&:join)
  end

  it "doesn't count bulkhead rejections as circuit failures" do
    # Fill and exceed bulkhead
    threads = Array.new(3) do
      Thread.new { service.process { sleep 0.1 } rescue nil }
    end

    threads.each(&:join)

    # Circuit should still be closed
    expect(service.circuit(:limited)).to be_closed
    expect(circuit_failure_count(:limited)).to eq(0)
  end
end
```

## Testing Hedged Requests

```ruby
RSpec.describe "hedged requests" do
  let(:service_class) do
    Class.new do
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
        # Stub this in tests
      end
    end
  end

  let(:service) { service_class.new }

  it "returns first successful response" do
    call_count = 0
    response_times = [0.1, 0.02, 0.15]  # Second call is fastest

    allow(service).to receive(:make_request) do
      delay = response_times[call_count]
      call_count += 1
      sleep delay
      "response-#{call_count}"
    end

    result = service.fetch_data

    # Should get result from fastest responder
    expect(result).to match(/response-\d/)
    expect(call_count).to be >= 2  # Multiple requests made
  end
end
```

## Testing Async Circuits

For a deeper understanding of BreakerMachines' asynchronous capabilities, refer to the [Async Mode](ASYNC.md) documentation.

```ruby
require 'async/rspec'

RSpec.describe "async circuits", :async do
  include Async::RSpec::Reactor

  let(:service_class) do
    Class.new do
      include BreakerMachines::DSL

      circuit :async_api do
        fiber_safe true
        threshold failures: 2, within: 30
        timeout 3
        fallback { "async fallback" }
      end

      def async_call
        circuit(:async_api).wrap { yield }
      end
    end
  end

  let(:service) { service_class.new }

  it "handles async operations" do |task|
    # Force failures
    2.times do
      expect {
        service.async_call { raise "Async error" }
      }.to raise_error("Async error")
    end

    # Circuit open, should use fallback
    result = service.async_call { "should not run" }
    expect(result).to eq("async fallback")
  end

  it "respects cooperative timeout" do |task|
    expect {
      service.async_call do
        task.sleep(5)  # Longer than 3 second timeout
      end
    }.to raise_error(BreakerMachines::CircuitTimeoutError)
  end
end
```

## Testing Storage Backends

For more details on configuring and implementing various storage backends, see the [Persistence Options](PERSISTENCE.md) guide.

```ruby
RSpec.describe "storage backends" do
  context "with Redis storage" do
    let(:redis) { MockRedis.new }

    around do |example|
      original_storage = BreakerMachines.config.default_storage
      BreakerMachines.config.default_storage = [:cache, cache_store: redis]
      example.run
      BreakerMachines.config.default_storage = original_storage
    end

    it "shares state across instances" do
      service1 = MyService.new
      service2 = MyService.new

      # Open circuit in first instance
      force_circuit_open(:shared)

      # Second instance sees open state
      expect(service2.circuit(:shared)).to be_open
    end
  end
end
```

## Custom Matchers

```ruby
# spec/support/matchers/circuit_matchers.rb
RSpec::Matchers.define :be_circuit_open do
  match do |circuit|
    circuit.state == :open
  end

  failure_message do |circuit|
    "expected circuit to be open, but was #{circuit.state}"
  end
end

RSpec::Matchers.define :have_failure_count do |expected|
  match do |circuit|
    circuit.failure_count == expected
  end

  failure_message do |circuit|
    "expected #{expected} failures, but had #{circuit.failure_count}"
  end
end

RSpec::Matchers.define :use_fallback do |expected|
  match do |actual|
    # Force circuit open
    circuit_name = @circuit_name || :default
    force_circuit_open(circuit_name)

    result = actual.call
    result == expected
  end

  chain :for_circuit do |name|
    @circuit_name = name
  end
end
```

## Shared Examples

```ruby
# spec/support/shared_examples/circuit_breaker.rb
RSpec.shared_examples "a circuit breaker" do
  it "starts in closed state" do
    expect(subject.circuit(circuit_name)).to be_closed
  end

  it "opens after failure threshold" do
    threshold.times do
      subject.circuit(circuit_name).wrap { raise "Error" } rescue nil
    end

    expect(subject.circuit(circuit_name)).to be_open
  end

  it "uses fallback when open" do
    force_circuit_open(circuit_name)

    result = subject.circuit(circuit_name).wrap { "should not run" }
    expect(result).to eq(expected_fallback)
  end
end

# Usage
RSpec.describe PaymentService do
  subject { described_class.new }

  it_behaves_like "a circuit breaker" do
    let(:circuit_name) { :stripe }
    let(:threshold) { 3 }
    let(:expected_fallback) { { error: "Payment queued" } }
  end
end
```

## Test Doubles and Stubs

```ruby
RSpec.describe "circuit breaker doubles" do
  let(:circuit_double) { instance_double(BreakerMachines::Circuit) }

  before do
    allow(BreakerMachines.registry).to receive(:get)
      .with(:payment)
      .and_return(circuit_double)
  end

  it "allows stubbing circuit behavior" do
    allow(circuit_double).to receive(:wrap)
      .and_yield
      .and_return("stubbed response")

    allow(circuit_double).to receive(:state).and_return(:open)

    service = PaymentService.new
    expect(service.process_payment).to eq("stubbed response")
  end
end
```

## Performance Testing

For more comprehensive performance monitoring and observability, refer to the [Observability Guide](OBSERVABILITY.md).

```ruby
RSpec.describe "circuit performance", performance: true do
  let(:service) { HighThroughputService.new }

  it "handles high request volume" do
    expect {
      10_000.times do
        service.circuit(:api).wrap { "success" }
      end
    }.to perform_under(100).ms
  end

  it "has minimal overhead" do
    expect {
      service.circuit(:api).wrap { "wrapped" }
    }.to perform_faster_than {
      "unwrapped"
    }.by_at_most(2).times
  end
end
```

## Integration Testing

```ruby
RSpec.describe "full integration", type: :integration do
  let(:service) { IntegratedService.new }

  it "handles cascading failures gracefully" do
    # Simulate downstream failure
    stub_request(:get, /api.example.com/)
      .to_timeout

    # First few requests fail
    3.times do
      expect { service.fetch_data }.to raise_error(Timeout::Error)
    end

    # Circuit opens, fallback used
    expect(service.fetch_data).to eq("cached data")

    # Circuit recovers when service is back
    travel_to(1.minute.from_now) do
      stub_request(:get, /api.example.com/)
        .to_return(body: "fresh data")

      expect(service.fetch_data).to eq("fresh data")
    end
  end
end
```

## Best Practices

1. **Use time helpers** - `travel_to` instead of `sleep`
2. **Reset state between tests** - Use `after(:each)` hooks
3. **Test edge cases** - Concurrent access, timeouts, storage failures
4. **Use shared examples** - For common circuit behaviors
5. **Mock external services** - Don't make real API calls in tests
6. **Test observability** - Verify logging and metrics. See [Observability Guide](OBSERVABILITY.md) for more details.

## Next Steps

- See [ActiveSupport Testing Guide](TESTING_ACTIVESUPPORT.md)
- Review [Rails Integration](RAILS_INTEGRATION.md) for Rails-specific patterns
- Explore [Advanced Patterns](ADVANCED_PATTERNS.md) for complex scenarios