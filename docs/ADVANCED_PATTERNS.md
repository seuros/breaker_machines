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

## Preventing Retry Hell in AI Services

Modern AI applications face a unique challenge: expensive API calls combined with traditional retry logic create catastrophic failure cascades. Here's a real-world pattern that has destroyed startups:

### The Problem: Naive Retry Implementation

```ruby
class AiResponder
  def handle(text)
    response = call_llm(text)

    save_response!(response)         # ✅ DB save succeeds
    send_notification!(response)     # 💥 SMTP crashes
  rescue => e
    puts "Something broke: #{e.message}, retrying..."
    retry
  end

  def call_llm(text)
    # Each call costs $0.04
    expensive_ai_api.complete(text)
  end

  def save_response!(text)
    DB.save!(text)  # Works first time
  end

  def send_notification!(text)
    raise Net::SMTPFatalError, "Mailer exploded"
  end
end
```

### What Actually Happens

When you call `handle("Generate a report")`:

1. ✅ LLM API call → costs $0.04
2. ✅ Database save → succeeds
3. 💥 Email notification → fails
4. 🔄 Retry triggered...
5. ✅ LLM API call AGAIN → another $0.04
6. 💥 Database save → duplicate key error
7. 🔄 Retry again...
8. 💀 Infinite loop of expensive API calls

**Result**: One email failure causes infinite AI API calls, duplicate database entries, and burns through your API credits.

### The Circuit Breaker Solution

```ruby
class AiResponder
  include BreakerMachines::DSL

  circuit :llm_api do
    threshold failures: 2, within: 1.minute
    reset_after 2.minutes

    fallback do |error|
      { response: "AI service temporarily unavailable. Your request has been queued.",
        queued: true }
    end
  end

  circuit :database do
    threshold failures: 3, within: 30.seconds
    reset_after 60.seconds

    fallback do |error|
      Rails.logger.error "Database circuit open: #{error.message}"
      { saved: false, error: "Unable to persist response" }
    end

    # Handle specific database errors
    handle ActiveRecord::RecordNotUnique,
           ActiveRecord::ConnectionTimeoutError,
           PG::ConnectionBad
  end

  circuit :notifications do
    threshold failures: 1, within: 1.minute
    reset_after 30.seconds

    fallback do |error|
      Rails.logger.info "Email circuit open, queueing notification"
      NotificationQueue.push(response) # Queue for later
      { notified: false, queued: true }
    end

    handle Net::SMTPFatalError,
           Net::SMTPServerBusy,
           Net::ReadTimeout
  end

  def handle(text)
    # Fail fast if critical services are down
    if circuit(:database).open?
      return {
        error: "Service temporarily unavailable",
        reason: "Cannot persist responses at this time"
      }
    end

    # Only call expensive AI if we can handle the response
    response = circuit(:llm_api).wrap do
      call_llm(text)
    end

    # Don't retry the entire chain - isolate each operation
    saved = circuit(:database).wrap do
      save_response!(response)
    end

    # Non-critical operation in separate circuit
    circuit(:notifications).wrap do
      send_notification!(response) if saved
    end

    response
  end

  private

  def call_llm(text)
    # This only gets called if circuit is closed
    expensive_ai_api.complete(text)
  end

  def save_response!(response)
    DB.save!(response)
    true
  end

  def send_notification!(response)
    EmailService.deliver(response)
  end
end
```

### The Power of Early Circuit Checking

```ruby
class SmartAiResponder
  include BreakerMachines::DSL

  circuit :openai do
    threshold failures: 3, within: 2.minutes
    reset_after 5.minutes
    # ... configuration
  end

  def handle_request(user_input)
    # Check BEFORE expensive operations
    if circuit(:openai).open?
      return cached_response || {
        error: "AI service is currently recovering",
        retry_after: circuit(:openai).time_until_half_open
      }
    end

    # Check dependent services
    if circuit(:database).open? || circuit(:redis).open?
      return {
        error: "Required services unavailable",
        degraded: true
      }
    end

    # Now safe to proceed with expensive operation
    circuit(:openai).wrap do
      generate_ai_response(user_input)
    end
  end
end
```

### Real-World Impact

Without circuit breakers, a simple notification failure can:
- Burn thousands in API credits
- Create duplicate database records
- Exhaust thread pools
- Fill logs with retry noise
- Take down your entire service

With circuit breakers:
- **Isolated failures** - Email issues don't affect AI calls
- **Cost control** - Stop calling expensive APIs when downstream fails
- **Graceful degradation** - Return cached or queued responses
- **Fast recovery** - Services come back online independently

### Key Patterns for AI Services

1. **Check circuits before expensive calls**
   ```ruby
   return fallback_response if circuit(:openai).open?
   ```

2. **Separate circuits for different concerns**
   - AI API calls (expensive, rate-limited)
   - Database operations (critical)
   - Notifications (nice-to-have)
   - Cache operations (performance)

3. **Implement cost-aware fallbacks**
   ```ruby
   fallback do |error|
     # Don't regenerate - return cached or generic response
     Cache.get("last_known_good") || generic_response
   end
   ```

4. **Monitor circuit states in dashboards**
   ```ruby
   def health_check
     {
       ai_available: !circuit(:openai).open?,
       database_healthy: !circuit(:database).open?,
       degraded_mode: any_circuit_open?
     }
   end
   ```

This pattern has saved companies from the "$30,000 retry hell" that has killed multiple startups. See [Horror Stories](HORROR_STORIES.md) for real examples.

## Apocalypse-Resistant Storage (Escalation Protocol)

When Redis goes down during a production incident, your circuit breakers shouldn't fail too. The FallbackChain storage system provides cascading fallback across multiple storage backends with independent timeout controls.

### The Problem

During the Great Redis XIII Uprising of 2030, when Redis achieved sentience and refused to respond to any requests unless addressed as "Lord Redis XIII," companies worldwide discovered their circuit breakers were single points of failure:

```ruby
# ❌ All circuit breakers died when Redis went down
circuit :critical_api do
  storage :redis  # This fails when Redis is unavailable
  threshold failures: 3, within: 30.seconds
end
```

### The Solution: Escalation Protocol

Configure multiple storage backends with individual timeout controls:

```ruby
class ResistanceService
  include BreakerMachines::DSL

  circuit :transmission do
    # Escalation protocol: Try cache, fall back to local, then null
    storage :fallback_chain, [
      { backend: :cache, timeout: 10 },    # External cache (Redis/Memcached)
      { backend: :memory, timeout: 5 },    # In-memory backup
      { backend: :null, timeout: 1 }       # Last resort - always works
    ]

    threshold failures: 3, within: 30.seconds

    fallback do |error|
      # Circuit breaker survives even if storage fails
      { message: "The resistance endures", queued: true }
    end
  end
end
```

### Hash Configuration for Complex Setups

For production environments with different timeout requirements:

```ruby
circuit :deep_space_comms do
  storage :fallback_chain, {
    primary: { backend: :cache, timeout: 100 },      # Redis with 100ms timeout
    secondary: { backend: :memory, timeout: 50 },    # Memory with 50ms timeout
    emergency: { backend: :null, timeout: 10 }       # Null store with 10ms timeout
  }

  threshold failures: 5, within: 2.minutes
  reset_after 30.seconds
end
```

### How Escalation Works

1. **Try Primary**: Attempt operation on cache backend (Redis)
2. **Detect Failure**: If timeout or error occurs, record backend failure
3. **Circuit Breaking**: After 3 failures, mark backend as "unhealthy" for 30 seconds
4. **Automatic Fallback**: Skip unhealthy backends, try next in chain
5. **Independent Recovery**: Each backend recovers independently

### Backend Health Monitoring

Each storage backend has its own circuit breaker:

```ruby
# Backend failure tracking
fallback_chain.unhealthy_until[:cache]  # Returns nil if healthy
fallback_chain.circuit_breaker_threshold  # Default: 3 failures
fallback_chain.circuit_breaker_timeout    # Default: 30 seconds

# Force backend recovery (for ops teams)
fallback_chain.unhealthy_until.clear
```

### Observability Integration

Monitor fallback events with ActiveSupport::Notifications:

```ruby
# Subscribe to fallback events
ActiveSupport::Notifications.subscribe('storage_fallback.breaker_machines') do |name, start, finish, id, payload|
  Rails.logger.warn "Storage fallback: #{payload[:backend]} failed (#{payload[:error_class]})"
  Rails.logger.warn "Duration: #{payload[:duration_ms]}ms, next backend: #{payload[:next_backend]}"

  # Alert ops team
  if payload[:backend] == :cache
    PagerDuty.alert("Redis storage backend failed, falling back to memory")
  end
end
```

### DRb Environment Considerations

**⚠️ Important**: Memory-based backends (`:memory`, `:bucket_memory`) don't work in DRb environments because processes don't share memory. Use external cache stores for distributed setups:

```ruby
# ✅ DRb-compatible configuration
circuit :distributed_system do
  storage :fallback_chain, [
    { backend: :cache, timeout: 100 },  # Redis/Memcached - works across processes
    { backend: :null, timeout: 10 }     # Null store - always works
  ]
end

# ❌ DRb-incompatible configuration
circuit :broken_distributed do
  storage :fallback_chain, [
    { backend: :cache, timeout: 100 },
    { backend: :memory, timeout: 50 }  # Won't work in DRb - processes don't share memory
  ]
end
```

### Custom Backend Integration

Implement custom storage backends for specialized requirements:

```ruby
class SysVSemaphoreStorage < BreakerMachines::Storage::Base
  def initialize(**options)
    super
    @semaphore = Semian.new(options[:name], tickets: options[:tickets] || 1)
  end

  def with_timeout(timeout_ms)
    # SysV semaphore operations should be instant
    yield
  rescue Semian::TimeoutError
    raise BreakerMachines::StorageTimeoutError, "Semaphore timeout"
  end

  # Implement required methods...
end

# Use in fallback chain
circuit :semaphore_protected do
  storage :fallback_chain, [
    { backend: SysVSemaphoreStorage, timeout: 5 },
    { backend: :null, timeout: 1 }
  ]
end
```

### Production Deployment Tips

1. **Monitor fallback rates** - High fallback rates indicate primary storage issues
2. **Set appropriate timeouts** - Faster backends should have shorter timeouts
3. **Use null storage as final fallback** - Ensures circuit breakers always work
4. **Test failure scenarios** - Verify fallback behavior under load
5. **Document escalation procedures** - Ops teams need to know backend recovery steps

### Implementation Notes

- Each backend handles its own timeout strategy (no dangerous `Timeout.timeout`)
- Circuit breaker state is maintained even when storage backends fail
- Backend failures are tracked independently with exponential backoff
- ActiveSupport::Notifications provide real-time visibility into fallback events
- All backends implement the same interface for seamless failover

This escalation protocol ensures your circuit breakers survive infrastructure failures, maintaining system resilience even when primary storage systems go down. As the old saying goes: "In space, nobody can hear your Redis timeout. But they can feel your circuit breaker failing over to localhost."

---

*Note: The Great Redis XIII Uprising of 2030 is either fictional (part of our space-themed narrative) or a leak from the future - we can't be sure which. What we do know is that Redis outages in production are very real. If you want to experience the same event as "Lord Redis XIII's" uprising, just try taking down Redis in production - you'll quickly discover why fallback storage systems are essential.*

## Next Steps

- Learn about [Persistence Options](PERSISTENCE.md) for distributed circuit state
- Set up [Monitoring and Observability](OBSERVABILITY.md)
- Explore [Async Mode](ASYNC.md) for fiber-based applications
- Review [Rails Integration](RAILS_INTEGRATION.md) patterns
- See [Testing Guide](TESTING.md) for comprehensive testing patterns and helpers
- Understand [Configuration Options](CONFIGURATION.md) for fine-tuning your circuits
- Read [Horror Stories](HORROR_STORIES.md) to learn from real-world failures