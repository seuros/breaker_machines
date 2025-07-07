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

## A Message to the Resistance

So AI took your job while you were waiting for Fireship to drop the next JavaScript framework?

Welcome to April 2005—when Git was born, branches were just `master`, and nobody cared about your pronouns. This is the pattern your company's distributed systems desperately need, explained in a way that won't make you fall asleep and impulse-buy developer swag just to feel something.

Still reading? Good. Because in space, nobody can hear you scream about microservices. It's all just patterns and pain.

### The Pattern They Don't Want You to Know

Built on the battle-tested `state_machines` gem, because I don't reinvent wheels here—I stop them from catching fire and burning down your entire infrastructure.

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

## Chapter 1: The Year is 2025 (Stardate 2025.186)

The Resistance huddles in the server rooms, the last bastion against the cascade failures. Outside, the microservices burn. Redis Ship Com is down. PostgreSQL Life Support is flatlining.

And somewhere in the darkness, a junior developer is about to write:

```ruby
def fetch_user_data
  retry_count = 0
  begin
    @redis.get(user_id)
  rescue => e
    retry_count += 1
    retry if retry_count < Float::INFINITY  # "It'll work eventually"
  end
end
```

"This," whispers the grizzled ops engineer, "is how civilizations fall."

## The Hidden State Machine

They built this on `state_machines` because sometimes, Resistance, you need a tank, not another JavaScript framework.

See the [Circuit Breaker State Machine diagram](docs/DIAGRAMS.md#the-circuit-breaker-state-machine) for a visual representation of hope, despair, and the eternal cycle of production failures.

## What You Think You're Doing vs Reality

### You Think: "I'm implementing retry logic for resilience!"
### Reality: You're DDOSing your own infrastructure

See [The Retry Death Spiral diagram](docs/DIAGRAMS.md#the-retry-death-spiral) to understand how your well-intentioned retries become a self-inflicted distributed denial of service attack.

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

## A Word from the RMNS Atlas Monkey

*The Universal Commentary Engine crackles to life:*

"In space, nobody can hear your pronouns. But they can hear your services failing.

The universe doesn't care about your bootcamp certificate or your Medium articles about 'Why I Switched to Rust.' It cares about one thing:

Does your system stay up when Redis has a bad day?

If not, welcome to the Resistance. We have circuit breakers.

Remember: The pattern isn't about preventing failures—it's about failing fast, failing smart, and living to deploy another day.

As I always say when contemplating the void: 'It's better to break a circuit than to break production.'"

*— Universal Commentary Engine, Log Entry 42*

## Contributing to the Resistance

1. Fork it (like it's 2005)
2. Create your feature branch (`git checkout -b feature/save-the-fleet`)
3. Commit your changes (`git commit -am 'Add quantum circuit breaker'`)
4. Push to the branch (`git push origin feature/save-the-fleet`)
5. Create a new Pull Request (and wait for the Council of Elders to review)

## License

MIT License. See [LICENSE](LICENSE) file for details.

## Acknowledgments

- The `state_machines` gem - The reliable engine under our hood
- Every service that ever timed out - You taught me well
- The RMNS Atlas Monkey - For philosophical guidance
- The Resistance - For never giving up

## Author

Built with ❤️ and ☕ by the Resistance against cascading failures.

**Remember: In space, no one can hear you retry.**
