# Configuration Guide

## Global Configuration

Configure BreakerMachines globally for all circuits:

```ruby
BreakerMachines.configure do |config|
  config.default_reset_timeout = 60  # seconds before attempting recovery
  config.default_failure_threshold = 5  # failures before circuit opens
  config.log_events = true  # Enable event logging
  config.default_storage = :memory  # Storage backend
  config.fiber_safe = false  # Enable fiber-safe mode (requires async gem)
end
```

## Circuit Configuration Options

### Basic Options

```ruby
circuit :service_name do
  # Failure threshold configuration
  threshold failures: 3, within: 60  # 3 failures in 60 seconds
  
  # Recovery settings
  reset_after 30  # Try recovery after 30 seconds
  
  # Fallback value when circuit is open
  fallback { { error: "Service unavailable" } }
  
  # Storage backend (optional, uses default if not specified)
  storage :memory  # or :cache, or custom storage instance
end
```

### Advanced Threshold Options

#### Error Rate Thresholds

Instead of absolute failure counts, use percentage-based thresholds:

```ruby
circuit :high_traffic_api do
  # Opens when 50% of calls fail, but only after minimum 10 calls
  threshold failure_rate: 0.5, minimum_calls: 10, within: 60
  reset_after 30
end
```

This prevents false positives in low-traffic scenarios while adapting to varying load.

#### Bulkheading - Resource Isolation

Limit concurrent calls to prevent resource exhaustion:

```ruby
circuit :limited_resource do
  max_concurrent 50  # Only 50 concurrent calls allowed
  threshold failures: 5, within: 30
  
  fallback { { error: "System at capacity", retry_after: 5 } }
end
```

**Important**: Bulkhead rejections (capacity limit) do NOT count as failures toward opening the circuit. They're a separate protection mechanism - the circuit tracks actual service failures, while bulkheading prevents overload.

### Storage Backends

For more details on storage options and distributed state, see the [Persistence Options](PERSISTENCE.md) guide.

#### Memory Storage (Default)
```ruby
circuit :local_service do
  storage :memory
  # State stored in process memory, not shared between instances
end
```

#### Cache Storage
Use Rails cache for distributed circuit state:

```ruby
circuit :distributed_service do
  storage :cache  # Uses Rails.cache (Redis, Memcached, etc.)
  threshold failures: 3, within: 60
end

# Or with custom cache store
circuit :custom_cache do
  storage :cache, cache_store: MyCustomCache.new
end
```

## Intelligent Threshold Configuration

For more context on why intelligent thresholds are crucial, refer to the [Horror Stories](HORROR_STORIES.md) and [Advanced Patterns](ADVANCED_PATTERNS.md) documentation.

### The Decision Matrix

| Service Criticality | Failure Threshold | Suggested Timeout | Reset Time | Example Services |
|---------------------|-------------------|-------------------|------------|------------------|
| 🚨 **CRITICAL**     | 2 failures/30s    | 3s (in client)    | 120s       | Payment, Auth, Orders |
| ⚠️ **HIGH**         | 3 failures/60s    | 5s (in client)    | 60s        | User API, Cart, Search |
| ✅ **MEDIUM**       | 5 failures/120s   | 10s (in client)   | 30s        | Notifications, Analytics |
| 💤 **LOW**          | 10 failures/300s  | 30s (in client)   | 15s        | Recommendations, Logging |

### The Smart Threshold Formula

```
threshold = base_threshold * (1 / criticality_score) * traffic_multiplier

Where:
- criticality_score: 1.0 (critical) to 0.1 (low priority)
- traffic_multiplier: avg_requests_per_minute / 1000
- base_threshold: 5 (default)
```

### Half-Open Configuration

Control how circuits test recovery:

```ruby
circuit :careful_service do
  threshold failures: 3, within: 60
  reset_after 30
  half_open_requests 3  # Test with 3 requests before fully closing
end
```

## Callbacks

Callbacks are essential for [Observability](OBSERVABILITY.md) and reacting to circuit state changes.

React to circuit state changes:

```ruby
circuit :monitored_service do
  threshold failures: 3, within: 60
  
  on_open do
    # Circuit has opened
    NotificationService.alert("Circuit opened!")
    Metrics.increment("circuit.opened")
  end
  
  on_close do
    # Circuit has closed (recovered)
    NotificationService.info("Circuit recovered")
    Metrics.increment("circuit.closed")
  end
  
  on_half_open do
    # Circuit is testing recovery
    Rails.logger.info("Testing circuit recovery")
  end
  
  on_reject do
    # Request rejected (circuit open)
    Metrics.increment("circuit.rejected")
  end
end
```

## Exception Configuration

Specify which exceptions should trigger the circuit:

```ruby
circuit :database do
  # Only these exceptions will count as failures
  exceptions [
    ActiveRecord::ConnectionTimeoutError,
    ActiveRecord::StatementTimeout,
    PG::ConnectionBad
  ]
  
  threshold failures: 3, within: 30
end
```

## Timeout Configuration

**Important**: BreakerMachines does NOT implement forceful timeouts. This is a deliberate design choice to prevent state corruption and ensure stability in Ruby applications. For a detailed explanation of why forceful timeouts are dangerous and how to implement cooperative timeouts, refer to the [Async Mode](ASYNC.md) documentation.

**Important**: BreakerMachines does NOT implement forceful timeouts. Configure timeouts in your client libraries:

```ruby
# ❌ WRONG: BreakerMachines doesn't enforce this
circuit :service do
  timeout 5  # This is documentation only!
end

# ✅ CORRECT: Configure timeout in your HTTP client
circuit :service do
  # Document your timeout intent
  # timeout 5
end

def make_request
  circuit(:service).wrap do
    HTTParty.get(url, timeout: 5)  # Actual timeout implementation
  end
end
```

## Fiber-Safe Mode

For async Ruby applications (Falcon, etc.):

```ruby
# Global configuration
BreakerMachines.configure do |config|
  config.fiber_safe = true
end

# Or per-circuit
circuit :async_service, fiber_safe: true do
  threshold failures: 3, within: 60
  timeout 5  # Safe cooperative timeout with Async::Task
end
```

See [Async Mode Documentation](ASYNC.md) for details.

## Environment-Specific Configuration

```ruby
BreakerMachines.configure do |config|
  case Rails.env
  when "production"
    config.log_events = true
    config.default_failure_threshold = 5
    config.default_reset_timeout = 60
  when "staging"
    config.log_events = true
    config.default_failure_threshold = 3
    config.default_reset_timeout = 30
  when "development"
    config.log_events = false
    config.default_failure_threshold = 1
    config.default_reset_timeout = 5
  end
end
```

## Dynamic Circuit Configuration

For more comprehensive examples and use cases for dynamic circuits, including webhook delivery patterns and global vs. local storage, see [Advanced Patterns](ADVANCED_PATTERNS.md).

### Circuit Templates

Define reusable configurations for dynamic circuits:

```ruby
class APIGateway
  include BreakerMachines::DSL

  # Template for reliable external services
  circuit_template :external_api do
    threshold failures: 5, within: 2.minutes
    reset_after 1.minute
    timeout 10.seconds
    
    fallback do |error|
      { error: "External service unavailable", retry_after: 60 }
    end
  end

  # Template for internal microservices
  circuit_template :internal_service do
    threshold failure_rate: 0.3, minimum_calls: 10, within: 1.minute
    reset_after 30.seconds
    timeout 5.seconds
    max_concurrent 50
  end

  # Template for critical services with strict limits
  circuit_template :critical_service do
    threshold failures: 2, within: 30.seconds
    reset_after 2.minutes
    timeout 15.seconds
    max_concurrent 10
    
    on_open do
      AlertService.critical_circuit_open(circuit_name)
    end
  end
end
```

### Dynamic Circuit Creation

Create circuits at runtime with custom configuration:

```ruby
# Basic dynamic circuit with template
circuit_breaker = dynamic_circuit(:new_service, template: :external_api)

# Dynamic circuit with template and custom overrides
api_circuit = dynamic_circuit(:payment_api, template: :external_api) do
  # Override template settings for payment API
  threshold failures: 3, within: 2.minutes
  timeout 8.seconds
  max_concurrent 10
  
  # Add specific callbacks
  on_open do
    PaymentFailureNotifier.notify
  end
end
```

For comprehensive examples including webhook delivery patterns, see [Advanced Patterns](ADVANCED_PATTERNS.md#dynamic-circuit-breakers).

### Template Inheritance

Templates support inheritance for hierarchical configuration:

```ruby
class TieredService
  include BreakerMachines::DSL

  # Base template
  circuit_template :base_service do
    threshold failures: 5, within: 1.minute
    reset_after 30.seconds
    timeout 5.seconds
  end

  # Free tier inherits from base
  circuit_template :free_tier do
    # Inherits from parent class templates
    threshold failures: 3, within: 1.minute  # Stricter limits
    max_concurrent 5
  end

  # Premium tier with more tolerance
  circuit_template :premium_tier do
    threshold failures: 10, within: 2.minutes
    max_concurrent 50
    timeout 10.seconds
  end

  def create_tenant_circuit(tenant_id, tier)
    template = case tier
               when :free then :free_tier
               when :premium then :premium_tier
               else :base_service
               end
    
    dynamic_circuit("tenant_#{tenant_id}".to_sym, template: template) do
      # Add tenant-specific configuration
      storage :cache, key_prefix: "tenant_#{tenant_id}"
      
      on_open do
        TenantNotifier.circuit_opened(tenant_id)
      end
    end
  end
end
```

### Memory Management for Dynamic Circuits

For long-lived objects that create many dynamic circuits, use global storage to prevent memory leaks:

```ruby
class WebhookService
  include BreakerMachines::DSL

  def deliver_webhook(domain, payload)
    # Use global storage to prevent memory accumulation
    circuit = dynamic_circuit("webhook_#{domain}".to_sym, global: true) do
      threshold failures: 3, within: 60
      fallback { { delivered: false, error: "Circuit open" } }
    end
    
    circuit.wrap { send_webhook(payload) }
  end
end
```

For local storage (backward compatible), you can manage circuits explicitly:

```ruby
class WebhookManager
  include BreakerMachines::DSL

  def initialize
    @domain_circuits = Concurrent::Map.new
  end

  def get_domain_circuit(domain)
    @domain_circuits.compute_if_absent(domain) do
      dynamic_circuit("webhook_#{domain}".to_sym, template: :webhook_default) do
        # Domain-specific configuration
        configure_for_domain(domain)
      end
    end
  end

  # Manually clean up circuits for domains that are no longer used
  def cleanup_unused_domains(active_domains)
    @domain_circuits.each do |domain, circuit|
      unless active_domains.include?(domain)
        circuit.reset!  # Clean final state
        @domain_circuits.delete(domain)
        circuit_instances.delete("webhook_#{domain}".to_sym)
      end
    end
  end

  # Get statistics for all domain circuits
  def domain_circuit_stats
    @domain_circuits.transform_values do |circuit|
      {
        state: circuit.state,
        failure_count: circuit.failure_count,
        last_failure: circuit.last_failure_time
      }
    end
  end
end
```

### Configuration Best Practices

1. **Use templates for common patterns** - Avoid duplicating configuration
2. **Override sparingly** - Only customize what's truly different per circuit
3. **Monitor dynamic circuits** - Track circuit creation and cleanup
4. **Use global storage for long-lived objects** - Prevent memory leaks (see [Advanced Patterns](ADVANCED_PATTERNS.md#global-vs-local-circuit-storage))
5. **Use meaningful names** - Make circuit names traceable to their purpose