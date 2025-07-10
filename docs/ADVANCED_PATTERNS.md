# Advanced Patterns

## For Those Who Don't Trust Magic: Captain Byroot's Guide to Explicit Circuit Construction

In the dark corners of the galaxy, where senior engineers huddle around legacy systems, there exists a faction that doesn't trust Domain Specific Languages. Led by the legendary Captain Byroot, they've seen too many frameworks come and go, too much magic turn into black holes of debugging despair.

This is for you, Battle-Hardened Engineer. You who follow Captain Byroot's philosophy: prefer explicit constructors over syntactic sugar. You who want to see exactly what objects are being created and when.

### The Magic Way (DSL for the Believers)

For those who trust in the ways of the DSL and enjoy declarative configuration:

```ruby
class HyperspaceCommunications
  include BreakerMachines::DSL

  circuit :subspace_relay do
    threshold failures: 5, within: 2.minutes
    reset_after 1.minute
    timeout 10.seconds
    storage :fallback_chain, [
      { backend: :cache, timeout: 10 },
      { backend: :null, timeout: 1 }
    ]

    fallback do |error|
      transmission_log.warn "Subspace relay circuit open: #{error.message}"
      { message: "Transmission queued for next hyperspace window", eta: 60 }
    end

    on_open { AlertSystem.red_alert("Subspace relay circuit opened") }
    on_close { AlertSystem.all_clear("Subspace relay circuit recovered") }
  end

  def transmit_coordinates(sector_id)
    circuit(:subspace_relay).wrap do
      subspace_transmitter.send_coordinates(sector_id)
    end
  end
end
```

### The Explicit Way (Captain Byroot's Preferred Method)

For engineers who follow Captain Byroot's wisdom and want transparent, explicit object creation:

```ruby
class HyperspaceCommunications
  # Circuit declared as a constant - visible, testable, dependency-injectable
  SUBSPACE_RELAY_CIRCUIT = BreakerMachines::Circuit.new(
    :subspace_relay,
    failure_threshold: 5,
    failure_window: 120, # 2 minutes in seconds - no magic time conversion
    reset_timeout: 60,   # 1 minute in seconds - explicit values
    timeout: 10,         # 10 seconds - you see exactly what you get
    storage: BreakerMachines::Storage::FallbackChain.new([
      { backend: :cache, timeout: 10 },
      { backend: :null, timeout: 1 }
    ]),
    fallback: ->(error) {
      transmission_log.warn "Subspace relay circuit open: #{error.message}"
      { message: "Transmission queued for next hyperspace window", eta: 60 }
    },
    on_open: -> { AlertSystem.red_alert("Subspace relay circuit opened") },
    on_close: -> { AlertSystem.all_clear("Subspace relay circuit recovered") }
  )

  def transmit_coordinates(sector_id)
    # No magic method calls - just plain old object interaction
    SUBSPACE_RELAY_CIRCUIT.wrap do
      subspace_transmitter.send_coordinates(sector_id)
    end
  end
end
```

### Parameter Mapping Reference

| DSL Syntax | Constructor Parameter | Type | Description |
|------------|----------------------|------|-------------|
| `threshold failures: 3, within: 60` | `failure_threshold: 3, failure_window: 60` | Integer, Integer (seconds) | Absolute failure count threshold |
| `threshold failure_rate: 0.5, minimum_calls: 10, within: 60` | `use_rate_threshold: true, failure_rate: 0.5, minimum_calls: 10, failure_window: 60` | Boolean, Float, Integer, Integer | Percentage-based threshold |
| `reset_after 30.seconds` | `reset_timeout: 30` | Integer (seconds) | Time before retry attempts |
| `timeout 10.seconds` | `timeout: 10` | Integer (seconds) | Individual operation timeout |
| `storage :redis` | `storage: :redis` | Symbol or Instance | Storage backend configuration |
| `fallback { result }` | `fallback: -> { result }` | Proc/Lambda | Fallback logic when circuit is open |
| `on_open { action }` | `on_open: -> { action }` | Proc/Lambda | Callback when circuit opens |
| `max_concurrent 5` | `max_concurrent: 5` | Integer | Bulkheading - limit concurrent requests |

### Advanced Battle-Tested Examples

**Rate-based thresholds for high-traffic space lanes:**
```ruby
# When you're dealing with heavy galactic traffic and need percentage-based failure detection
HYPERSPACE_TOLL_CIRCUIT = BreakerMachines::Circuit.new(
  :hyperspace_toll_booth,
  use_rate_threshold: true,
  failure_rate: 0.3,        # 30% failure rate triggers circuit
  minimum_calls: 20,        # Need at least 20 ships before evaluating
  failure_window: 60,       # In the last 60 seconds of space-time
  reset_timeout: 45         # Wait 45 seconds before trying again
)
```

**Bulkheading for limited warp core access:**
```ruby
# When your warp core can only handle so many concurrent requests
WARP_CORE_CIRCUIT = BreakerMachines::Circuit.new(
  :warp_core_access,
  failure_threshold: 3,
  failure_window: 30,
  max_concurrent: 5,        # Only 5 concurrent warp core operations
  timeout: 30               # 30 second timeout per warp calculation
)
```

**Apocalypse-resistant storage for critical systems:**
```ruby
# When you absolutely, positively need your circuit to survive the heat death of the universe
LIFE_SUPPORT_CIRCUIT = BreakerMachines::Circuit.new(
  :life_support_systems,
  failure_threshold: 2,     # Very sensitive - can't afford many failures
  failure_window: 60,
  storage: BreakerMachines::Storage::FallbackChain.new([
    { backend: :cache, timeout: 10 },       # Try Redis first (fast)
    { backend: :activerecord, timeout: 100 }, # Fall back to database (reliable)
    { backend: :null, timeout: 1 }          # Last resort (always works)
  ])
)
```

### When to Choose Your Path

**Join the DSL believers when:**
- Your team trusts in the power of declarative configuration
- You're building new starships with many circuit breakers
- You appreciate the convenience of magical syntax sugar
- Your crew uses Rails and believes in convention over configuration
- You don't mind some abstraction for the sake of readability

**Join Captain Byroot's explicit resistance when:**
- Your team has been burned by magic before and trusts no one
- You want circuits stored in constants that are visible and testable
- You need to inject circuit dependencies for proper testing
- Your engineering philosophy leans toward functional programming
- You're building libraries where transparency matters more than convenience
- You've debugged too many "Rails magic" issues at 3 AM

**The Truth:** Both paths lead to the same destination. The DSL compiles down to the exact same Circuit objects with identical performance. Choose your weapon based on your team's battle scars and philosophical alignment.

*"At the end of the day, a good old class with a constructor stored in a constant is much more transparent. Just my 2 space credits though."* — Captain Byroot

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

When the universe ends and your primary storage joins the cosmic void, your circuit breakers shouldn't follow suit. The FallbackChain storage system provides the ultimate defense against Lord Redis XIII's unpredictable moods.

### Quick Example

```ruby
class ResistanceService
  include BreakerMachines::DSL

  circuit :transmission do
    # Escalation protocol: Try cache, fall back to database, then null
    storage :fallback_chain, [
      { backend: :cache, timeout: 10 },         # Redis - 10ms
      { backend: :activerecord, timeout: 100 }, # Database - 100ms
      { backend: :null, timeout: 1 }            # Last resort
    ]

    threshold failures: 3, within: 30.seconds

    fallback do |error|
      { message: "The resistance endures", queued: true }
    end
  end
end
```

### How It Works

1. **Try Primary** → Redis with 10ms timeout
2. **On Failure** → Automatically try database with 100ms timeout
3. **Final Fallback** → Null storage (always succeeds)
4. **Health Tracking** → Unhealthy backends are skipped for 30 seconds
5. **Recovery** → Backends recover independently

### Comprehensive Documentation

For complete configuration options, observability integration, DRb considerations, custom backend examples, and production deployment strategies, see the **[Fallback Chain Storage](PERSISTENCE.md#fallback-chain-storage-apocalypse-resistant)** section in the Persistence guide.

**Key Features:**
- ✅ **Independent timeout controls** for each backend
- ✅ **Automatic health monitoring** with circuit breaking per backend
- ✅ **Comprehensive instrumentation** via ActiveSupport::Notifications
- ✅ **DRb compatibility** warnings and guidelines
- ✅ **Custom backend integration** patterns
- ✅ **Production deployment** best practices
