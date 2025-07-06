# BreakerMachines

A battle-tested Ruby implementation of the Circuit Breaker pattern, built on `state_machines` for reliable distributed systems protection.

## Quick Start

```bash
gem 'breaker_machines'
```

```ruby
class PaymentService
  include BreakerMachines::DSL

  circuit :stripe do
    threshold failures: 3, within: 1.minute
    reset_after 30.seconds
    fallback { { error: "Payment queued for later" } }
  end

  def charge(amount)
    circuit(:stripe).wrap do
      Stripe::Charge.create(amount: amount)
    end
  end
end
```

## Features

- **Thread-safe** circuit breaker implementation
- **Fiber-safe mode** for async Ruby (Falcon, async gem)
- **Hedged requests** for latency reduction
- **Multiple backends** with automatic failover
- **Bulkheading** to limit concurrent requests
- **Percentage-based thresholds** with minimum call requirements
- **Dynamic circuit breakers** with templates for runtime creation
- **Pluggable storage** (Memory, Redis, Custom)
- **Rich callbacks** and instrumentation
- **ActiveSupport::Notifications** integration

## Documentation

- **Getting Started Guide** (docs/GETTING_STARTED.md) - Installation and basic usage
- **Configuration Reference** (docs/CONFIGURATION.md) - All configuration options
- **Advanced Patterns** (docs/ADVANCED_PATTERNS.md) - Complex scenarios and patterns
- **Persistence Options** (docs/PERSISTENCE.md) - Storage backends and distributed state
- **Observability Guide** (docs/OBSERVABILITY.md) - Monitoring and metrics
- **Async Mode** (docs/ASYNC.md) - Fiber-safe operations
- **Testing Guide** (docs/TESTING.md) - Testing strategies
  - [RSpec Testing](docs/TESTING_RSPEC.md)
  - [ActiveSupport Testing](docs/TESTING_ACTIVESUPPORT.md)
- **Rails Integration** (docs/RAILS_INTEGRATION.md) - Rails-specific patterns
- **Horror Stories** (docs/HORROR_STORIES.md) - Real production failures and lessons learned
- **API Reference** (docs/API_REFERENCE.md) - Complete API documentation

## Why BreakerMachines?

Built on the battle-tested `state_machines` gem, BreakerMachines provides production-ready circuit breaker functionality without reinventing the wheel. It's designed for modern Ruby applications with first-class support for fibers, async operations, and distributed systems.

See [Why I Open Sourced This](docs/WHY_OPEN_SOURCE.md) for the full story.

## Production-Ready Features

### Hedged Requests
Reduce latency by sending duplicate requests and using the first successful response:

```ruby
circuit :api do
  hedged do
    delay 100           # Start second request after 100ms
    max_requests 3      # Maximum parallel requests
  end
end
```

### Multiple Backends
Configure automatic failover across multiple service endpoints:

```ruby
circuit :multi_region do
  backends [
    -> { fetch_from_primary },
    -> { fetch_from_secondary },
    -> { fetch_from_tertiary }
  ]
end
```

### Percentage-Based Thresholds
Open circuits based on error rates instead of absolute counts:

```ruby
circuit :high_traffic do
  threshold failure_rate: 0.5, minimum_calls: 10, within: 60
end
```

### Dynamic Circuit Breakers
Create circuit breakers at runtime for webhook delivery, API proxies, or per-tenant isolation:

```ruby
class WebhookService
  include BreakerMachines::DSL

  circuit_template :webhook_default do
    threshold failures: 3, within: 1.minute
    fallback { |error| { delivered: false, error: error.message } }
  end

  def deliver_webhook(url, payload)
    domain = URI.parse(url).host
    circuit_name = "webhook_#{domain}".to_sym
    
    dynamic_circuit(circuit_name, template: :webhook_default) do
      # Custom per-domain configuration
      if domain.include?('reliable-service.com')
        threshold failures: 5, within: 2.minutes
      end
    end.wrap do
      send_webhook(url, payload)
    end
  end
end
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

MIT License. See [LICENSE](LICENSE) file for details.

## Author

Built with ❤️ and ☕ by the Resistance against cascading failures.

---

*Remember: Without circuit breakers, even AI can enter infinite loops of existential confusion. Don't let your services have an existential crisis.*