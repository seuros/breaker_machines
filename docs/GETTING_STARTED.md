# Getting Started with BreakerMachines

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'breaker_machines'
```

And then execute:
```bash
$ bundle install
```

Or install it yourself as:
```bash
$ gem install breaker_machines
```

## Basic Concepts

BreakerMachines implements the Circuit Breaker pattern to prevent cascading failures in distributed systems. Think of it like an electrical circuit breaker in your house - when things go wrong, it trips to prevent further damage.

To understand *why* this matters, read [Why I Open Sourced This](../WHY_OPEN_SOURCE.md) and dive into the [Horror Stories](HORROR_STORIES.md) of what happens when you don't have them.

### Circuit States

1. **Closed** - Normal operation, requests pass through
2. **Open** - Circuit has tripped, requests are rejected or use fallback
3. **Half-Open** - Testing if the service has recovered

## Your First Circuit Breaker

### Simple Example

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

### What's Happening?

1. After 3 failures within 1 minute, the circuit opens
2. While open, calls immediately return the fallback value
3. After 30 seconds, the circuit enters half-open state
4. The next call tests if the service is healthy
5. If successful, circuit closes; if not, it reopens

## Common Patterns

### Service Integration

```ruby
class ExternalAPIClient
  include BreakerMachines::DSL

  circuit :api do
    threshold failures: 5, within: 2.minutes
    reset_after 1.minute

    fallback do |error|
      case error
      when Timeout::Error
        { error: "Service is slow, please retry" }
      when Net::HTTPServerError
        { error: "Service is down" }
      else
        { error: "Temporary issue" }
      end
    end
  end

  def fetch_data
    circuit(:api).wrap do
      # Your API call here
      HTTParty.get("https://api.example.com/data")
    end
  end
end
```

### Database Protection

```ruby
class UserService
  include BreakerMachines::DSL

  circuit :database do
    threshold failures: 3, within: 30.seconds
    reset_after 45.seconds

    fallback do
      # Return cached data or degraded response
      Rails.cache.read("users:fallback") || []
    end
  end

  def find_users
    circuit(:database).wrap do
      User.where(active: true).limit(100)
    end
  end
end
```

## Dynamic Circuit Breakers

For scenarios where you need circuit breakers created at runtime (like webhook delivery to different domains):

```ruby
class WebhookService
  include BreakerMachines::DSL

  # Define a reusable template
  circuit_template :webhook_default do
    threshold failures: 3, within: 1.minute
    reset_after 30.seconds
    timeout 5.seconds

    fallback do |error|
      { delivered: false, error: error.message, retry_later: true }
    end
  end

  def deliver_webhook(webhook_url, payload)
    domain = URI.parse(webhook_url).host
    circuit_name = "webhook_#{domain}".to_sym

    # Create circuit breaker for this domain if it doesn't exist
    circuit_breaker = dynamic_circuit(circuit_name, template: :webhook_default) do
      # Custom configuration per domain
      if domain.include?('reliable-service.com')
        threshold failures: 5, within: 2.minutes
      elsif domain.include?('flaky-service.com')
        threshold failure_rate: 0.7, minimum_calls: 3
      end
    end

    circuit_breaker.wrap do
      send_webhook(webhook_url, payload)
    end
  end

  private

  def send_webhook(url, payload)
    # Your webhook sending logic here
    HTTParty.post(url, body: payload.to_json, timeout: 5)
  end
end
```

This creates a separate circuit breaker for each domain, allowing independent failure tracking and recovery.

## Next Steps

- Learn about [Configuration Options](CONFIGURATION.md) for fine-tuning your circuits
- Explore [Advanced Patterns](ADVANCED_PATTERNS.md) for complex scenarios
- Set up [Monitoring and Observability](OBSERVABILITY.md)
- Understand [Persistence Options](PERSISTENCE.md) for distributed systems
- Dive into [Testing Patterns](TESTING.md) to prove your worth
- Explore [Asynchronous Support](ASYNC.md) and [Async Storage Examples](ASYNC_STORAGE_EXAMPLES.md) for modern Ruby applications
- See [Rails Integration Examples](RAILS_INTEGRATION.md) for common web application patterns