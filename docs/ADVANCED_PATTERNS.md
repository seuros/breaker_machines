# Advanced Patterns

## Dynamic Circuit Breakers

Create circuit breakers at runtime with configurable templates - perfect for webhook delivery, API proxies, or any scenario where you need per-entity protection. For more details on defining and using circuit templates, refer to the [Configuration Guide](CONFIGURATION.md).

### Global vs Local Circuit Storage

When creating dynamic circuits, you can choose between local and global storage. For a deeper dive into various storage options and their implications for distributed systems, refer to the [Persistence Options](PERSISTENCE.md) guide.

```ruby
class WebhookService
  include BreakerMachines::DSL

  def deliver_webhook(domain, payload)
    # Local storage (default) - stored in this instance
    local_circuit = dynamic_circuit("webhook_#{domain}".to_sym, global: false) do
      threshold failures: 3, within: 60
      fallback { { delivered: false, error: "Circuit open" } }
    end

    # Global storage - shared across all instances, prevents memory leaks
    global_circuit = dynamic_circuit("webhook_#{domain}".to_sym, global: true) do
      threshold failures: 3, within: 60
      fallback { { delivered: false, error: "Circuit open" } }
    end
  end
end
```

**When to use Global Storage (`global: true`):**
- Long-lived objects that process many dynamic entities (webhook domains, tenant IDs, etc.)
- Prevents memory leaks when circuits accumulate in instance variables
- Circuits are shared across all instances of the class
- Automatic cleanup via WeakRef when owner is garbage collected

**When to use Local Storage (`global: false`):**
- Short-lived objects or when you need instance-specific circuit state
- Backward compatible with existing code
- Circuits are stored in the instance's `@circuit_instances` hash

**Memory Leak Prevention:**

```ruby
# ❌ Memory leak scenario - avoid this pattern with long-lived objects
class LongLivedWebhookProcessor
  include BreakerMachines::DSL
  
  def process_webhooks_forever
    loop do
      unique_domains.each do |domain|
        # This accumulates circuits in @circuit_instances forever!
        dynamic_circuit("webhook_#{domain}".to_sym, global: false) { ... }
      end
    end
  end
end

# ✅ Memory-safe pattern - use global storage
class LongLivedWebhookProcessor
  include BreakerMachines::DSL
  
  def process_webhooks_forever
    loop do
      unique_domains.each do |domain|
        # Global circuits prevent memory accumulation
        dynamic_circuit("webhook_#{domain}".to_sym, global: true) { ... }
      end
    end
  end
end
```

### Circuit Templates

Define reusable circuit configurations:

```ruby
class WebhookService
  include BreakerMachines::DSL

  # Templates for different endpoint types
  circuit_template :reliable_endpoint do
    threshold failures: 5, within: 2.minutes
    reset_after 1.minute
    timeout 10.seconds
  end

  circuit_template :flaky_endpoint do
    threshold failure_rate: 0.7, minimum_calls: 3, within: 1.minute
    reset_after 30.seconds
    timeout 5.seconds
  end

  circuit_template :critical_endpoint do
    threshold failures: 2, within: 30.seconds
    reset_after 2.minutes
    timeout 15.seconds
    max_concurrent 5
  end
end
```

### Dynamic Circuit Creation

Create circuits on-demand with custom configuration:

```ruby
class WebhookDeliveryService
  include BreakerMachines::DSL

  def deliver_webhook(webhook_url, payload)
    domain = extract_domain(webhook_url)
    circuit_name = "webhook_#{domain}".to_sym
    
    # Create circuit breaker for this domain if it doesn't exist
    # Use global storage since webhook services are typically long-lived
    circuit_breaker = dynamic_circuit(circuit_name, template: :reliable_endpoint, global: true) do
      # Custom configuration based on domain
      if domain.include?('amazonaws.com')
        threshold failures: 8, within: 3.minutes
        timeout 15.seconds
      elsif domain.include?('herokuapp.com')
        threshold failure_rate: 0.6, minimum_calls: 5
        timeout 8.seconds
      end
      
      fallback do |error|
        {
          delivered: false,
          error: error.message,
          retry_at: calculate_retry_time(domain, error)
        }
      end
    end
    
    circuit_breaker.wrap do
      send_webhook(webhook_url, payload)
    end
  end

  private

  def extract_domain(url)
    URI.parse(url).host.downcase
  rescue URI::InvalidURIError
    'invalid_domain'
  end
end
```

### Template Application

Apply templates to existing circuits:

```ruby
class APIProxyService
  include BreakerMachines::DSL

  def setup_client_circuit(client_id, tier: :standard)
    template = case tier
               when :premium then :reliable_endpoint
               when :enterprise then :critical_endpoint
               else :flaky_endpoint
               end
    
    apply_template("client_#{client_id}".to_sym, template)
  end

  def proxy_request(client_id, request)
    circuit_name = "client_#{client_id}".to_sym
    
    circuit_instances[circuit_name].wrap do
      forward_request(request)
    end
  end
end
```

### Bulk Operations with Individual Protection

Protect bulk operations while maintaining per-entity circuit isolation:

```ruby
class BulkWebhookService
  include BreakerMachines::DSL

  def deliver_bulk_webhooks(webhook_requests)
    results = Concurrent::Array.new
    threads = []
    
    webhook_requests.each do |request|
      threads << Thread.new do
        domain = extract_domain(request[:url])
        circuit_name = "webhook_#{domain}".to_sym
        
        result = dynamic_circuit(circuit_name, template: :reliable_endpoint).wrap do
          send_webhook(request[:url], request[:payload])
        end
        
        results << { request: request, result: result }
      rescue => e
        results << { 
          request: request, 
          result: { delivered: false, error: e.message } 
        }
      end
    end
    
    threads.each(&:join)
    results.to_a
  end
end
```

### Per-Tenant Circuit Isolation

Create isolated circuits for multi-tenant applications:

```ruby
class MultiTenantService
  include BreakerMachines::DSL

  circuit_template :tenant_default do
    threshold failure_rate: 0.5, minimum_calls: 10, within: 2.minutes
    reset_after 1.minute
    
    fallback do |error|
      { error: "Service temporarily unavailable for tenant", retry_after: 60 }
    end
  end

  def process_tenant_request(tenant_id, request)
    circuit_name = "tenant_#{tenant_id}".to_sym
    
    # Create tenant-specific circuit with custom limits
    # Use global storage since this service processes many tenants
    tenant_circuit = dynamic_circuit(circuit_name, template: :tenant_default, global: true) do
      # Adjust limits based on tenant tier
      tier = get_tenant_tier(tenant_id)
      
      case tier
      when :enterprise
        threshold failures: 10, within: 5.minutes
        max_concurrent 50
      when :professional  
        threshold failures: 5, within: 2.minutes
        max_concurrent 20
      else # free tier
        threshold failures: 3, within: 1.minute
        max_concurrent 5
      end
      
      on_open do
        notify_tenant_admin(tenant_id, "Service degraded")
      end
    end
    
    tenant_circuit.wrap do
      process_request(request)
    end
  end

  private

  def get_tenant_tier(tenant_id)
    # Your tenant tier lookup logic
    :professional
  end

  def notify_tenant_admin(tenant_id, message)
    # Your tenant notification logic
  end
end
```

## Parallel Fallback Chains

Execute multiple fallback strategies in parallel and use the first successful result:

```ruby
class ResilientDataService
  include BreakerMachines::DSL

  circuit :data_fetch do
    threshold failures: 3, within: 30.seconds
    
    # Execute all fallbacks in parallel, take first success
    parallel_fallback [
      ->(error) { fetch_from_cache(error) },
      ->(error) { fetch_from_replica(error) },
      ->(error) { fetch_from_backup_region(error) }
    ]
  end

  def get_data(id)
    circuit(:data_fetch).wrap do
      primary_db.find(id)
    end
  end
  
  private
  
  def primary_db
    # Your primary database connection
  end
  
  def fetch_from_cache(error)
    # Your cache fetching logic
    Rails.cache.read("data:#{id}")
  end
  
  def fetch_from_replica(error)
    # Your replica fetching logic
    replica_db.find(id)
  end
  
  def fetch_from_backup_region(error)
    # Your backup region logic
    BackupRegion.fetch(id)
  end
  
  def replica_db
    # Your replica database connection
  end
end
```

## Hedged Requests

Reduce latency by sending duplicate requests and using the first successful response:

```ruby
class LowLatencyService
  include BreakerMachines::DSL

  circuit :api do
    threshold failures: 3, within: 1.minute
    
    # Enable hedged requests
    hedged do
      delay 100           # Start second request after 100ms
      max_requests 3      # Maximum parallel requests
    end
  end

  def fetch_data
    circuit(:api).wrap do
      # If first request is slow, a second (and third) 
      # will be started automatically
      http_client.get('/api/data')
    end
  end
  
  private
  
  def http_client
    # Your HTTP client implementation
  end
end
```

## Multiple Backends

Configure multiple backend services for automatic failover:

```ruby
class MultiRegionService
  include BreakerMachines::DSL

  circuit :geo_distributed do
    threshold failures: 2, within: 30.seconds
    
    # Define backend services
    backends [
      -> { fetch_from_us_east },
      -> { fetch_from_eu_west },
      -> { fetch_from_asia_pacific }
    ]
    
    # Optional: combine with hedging
    hedged do
      delay 50  # Try next region after 50ms
    end
  end

  def get_user_data(user_id)
    circuit(:geo_distributed).wrap do
      # Block is ignored when backends are configured
      raise "This won't be called"
    end
  end
  
  private
  
  def fetch_from_us_east
    # Your US East implementation
  end
  
  def fetch_from_eu_west
    # Your EU West implementation
  end
  
  def fetch_from_asia_pacific
    # Your Asia Pacific implementation
  end
end
```

## Adaptive Thresholds

Implement dynamic thresholds based on traffic patterns:

```ruby
class AdaptiveService
  include BreakerMachines::DSL

  circuit :adaptive_api do
    # Use percentage-based thresholds
    threshold failure_rate: 0.5, minimum_calls: 10, within: 1.minute
    
    # Adjust reset time based on time of day
    reset_after -> { business_hours? ? 30.seconds : 2.minutes }
    
    on_open do
      # Notify ops team during business hours
      AlertService.page_on_call if business_hours?
    end
  end

  private

  def business_hours?
    Time.current.hour.between?(9, 17)
  end
end
```

## Chained Circuits

Create dependencies between circuits for complex service topologies:

```ruby
class ChainedService
  include BreakerMachines::DSL

  circuit :database do
    threshold failures: 3, within: 30.seconds
    fallback { [] }
  end

  circuit :cache do
    threshold failures: 5, within: 1.minute
    fallback { nil }
  end

  circuit :api do
    threshold failures: 3, within: 1.minute
    
    fallback do
      # Check dependent services
      if circuit(:database).open? && circuit(:cache).open?
        { error: "All systems down", retry_after: 300 }
      else
        { error: "Partial outage", data: fetch_from_available }
      end
    end
  end
  
  private
  
  def fetch_from_available
    # Your logic to fetch from available services
  end
end
```

## Request Deduplication

Prevent duplicate requests during circuit recovery:

```ruby
class DeduplicatedService
  include BreakerMachines::DSL

  def initialize
    @request_cache = Concurrent::Map.new
  end

  circuit :expensive_api do
    threshold failures: 2, within: 30.seconds
    
    on_half_open do
      # Clear request cache when testing recovery
      @request_cache.clear
    end
  end

  def fetch_expensive_data(key)
    # Deduplicate concurrent requests for same key
    @request_cache.compute_if_absent(key) do
      circuit(:expensive_api).wrap do
        expensive_api_call(key)
      end
    end
  end
  
  private
  
  def expensive_api_call(key)
    # Your expensive API implementation
  end
end
```

## Circuit Coordination

Coordinate multiple circuits for complex workflows:

```ruby
class WorkflowService
  include BreakerMachines::DSL

  circuit :step1 do
    threshold failures: 3, within: 1.minute
  end

  circuit :step2 do
    threshold failures: 3, within: 1.minute
  end

  circuit :step3 do
    threshold failures: 3, within: 1.minute
  end

  def execute_workflow(data)
    # Check all circuits before starting
    circuits = [:step1, :step2, :step3]
    open_circuits = circuits.select { |name| circuit(name).open? }
    
    if open_circuits.any?
      return {
        error: "Workflow unavailable",
        blocked_by: open_circuits,
        retry_after: earliest_recovery_time(open_circuits)
      }
    end

    # Execute workflow
    result1 = circuit(:step1).wrap { process_step1(data) }
    result2 = circuit(:step2).wrap { process_step2(result1) }
    circuit(:step3).wrap { process_step3(result2) }
  end

  private

  def earliest_recovery_time(circuit_names)
    circuit_names.map { |name| circuit(name).recovery_time }.min
  end
  
  def process_step1(data)
    # Your step 1 implementation
  end
  
  def process_step2(data)
    # Your step 2 implementation
  end
  
  def process_step3(data)
    # Your step 3 implementation
  end
end
```

## Next Steps

- Learn about [Persistence Options](PERSISTENCE.md) for distributed circuit state
- Set up [Monitoring and Observability](OBSERVABILITY.md)
- Explore [Async Mode](ASYNC.md) for fiber-based applications
- Review [Rails Integration](RAILS_INTEGRATION.md) patterns
- See [Testing Guide](TESTING.md) for comprehensive testing patterns and helpers
- Understand [Configuration Options](CONFIGURATION.md) for fine-tuning your circuits
- Read [Horror Stories](HORROR_STORIES.md) to learn from real-world failures