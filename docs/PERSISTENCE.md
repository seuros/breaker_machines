# Persistence and Distributed State

## Overview

BreakerMachines supports multiple storage backends for circuit state, enabling distributed systems to share circuit breaker state across instances.

## Storage Backends

BreakerMachines supports multiple storage backends for circuit state, enabling distributed systems to share circuit breaker state across instances. For general configuration of storage, refer to the [Configuration Guide](CONFIGURATION.md).

### Memory Storage (Default)

In-process memory storage, perfect for single-instance applications:

```ruby
circuit :local_service do
  storage :memory
  threshold failures: 3, within: 60.seconds
end
```

**Pros:**
- Zero latency
- No external dependencies
- Thread-safe

**Cons:**
- State lost on restart
- Not shared between instances

### Bucket Memory Storage

Enhanced memory storage with time-windowed buckets:

```ruby
circuit :analytics do
  storage :bucket_memory
  threshold failures: 5, within: 5.minutes
end
```

This is the default storage and provides accurate time-window tracking for failure rates.

### Cache Storage (Rails.cache)

Use your existing Rails cache infrastructure:

```ruby
circuit :shared_service do
  storage :cache
  threshold failures: 3, within: 60.seconds
end

# Or with custom cache store
circuit :custom_cached do
  storage :cache, cache_store: Redis::Store.new
end
```

**Pros:**
- Shared state across instances
- Works with Redis, Memcached, etc.
- Leverages existing infrastructure

**Cons:**
- Network latency
- Cache eviction policies may affect state

### Fallback Chain Storage (Apocalypse-Resistant)

When the universe ends and your primary storage joins the cosmic void, fallback chains ensure your circuits survive any catastrophe:

```ruby
# The Multi-Level Apocalypse Defense System
circuit :payment_of_last_resort do
  storage :fallback_chain, {
    primary: { backend: :cache, timeout: 5 },        # Normal times (Redis)
    fallback: { backend: :memory, timeout: 2 },      # Redis outage (in-memory)
    final: { backend: :null, timeout: 1 }            # WW3 scenario (fail-open)
  }

  threshold failures: 3, within: 60.seconds
  reset_after 30.seconds
end
```

**How it works:**
1. **Primary Backend**: Try Redis/cache with 5ms timeout
2. **Fallback Backend**: On timeout/error, try in-memory with 2ms timeout
3. **Final Backend**: If all else fails, use null storage (always succeeds)

**Dynamic Timeout Allocation:**

```ruby
# For the truly paranoid
storage :fallback_chain, ->(timeout:) {
  base_timeout = timeout || 10
  [
    { backend: :cache, timeout: base_timeout * 0.6 },      # 60% for Redis
    { backend: :memory, timeout: base_timeout * 0.3 },     # 30% for memory
    { backend: :null, timeout: base_timeout * 0.1 }        # 10% for chaos
  ]
}
```

**Observability:**

Each fallback emits `ActiveSupport::Notifications` events:

```ruby
ActiveSupport::Notifications.subscribe("storage_fallback.breaker_machines") do |name, started, finished, unique_id, data|
  Rails.logger.warn "Storage fallback: #{data[:backend]} → #{data[:next_backend]} (#{data[:error_message]})"

  # Track metrics
  StatsD.increment("circuit.storage.fallback", tags: {
    from: data[:backend],
    to: data[:next_backend],
    error: data[:error_class]
  })
end
```

**Pros:**
- Survives Redis outages, network partitions, and apocalyptic scenarios
- Millisecond-precise timeout control
- Automatic circuit breaker per backend (unhealthy backends get bypassed)
- Full observability via ActiveSupport::Notifications
- Graceful degradation from distributed → local → fail-open

**Cons:**
- More complex configuration
- Potential state divergence between backends
- User must handle sync between storage layers

### Custom Storage Implementation

Create your own storage adapter by inheriting from `BreakerMachines::Storage::Base` and implementing the required methods:

#### SysV Semaphore Example (Shopify-style)

```ruby
class SysVSemaphoreStorage < BreakerMachines::Storage::Base
  def initialize(semaphore_key: nil, **options)
    super(**options)
    @semaphore_key = semaphore_key || generate_semaphore_key
    @semaphore = SysV::Semaphore.new(@semaphore_key, create: true)
  end

  def with_timeout(timeout_ms)
    # Use sem_trywait for immediate non-blocking check
    if @semaphore.try_wait
      begin
        yield
      ensure
        @semaphore.post
      end
    else
      raise BreakerMachines::StorageTimeoutError,
            "SysV semaphore not available after #{timeout_ms}ms"
    end
  end

  def get_status(circuit_name)
    with_timeout(5) do
      # Read from shared memory mapped to semaphore
      shared_data = read_shared_memory(circuit_name)
      return nil unless shared_data

      {
        status: shared_data[:status].to_sym,
        opened_at: shared_data[:opened_at]
      }
    end
  end

  def set_status(circuit_name, status, opened_at = nil)
    with_timeout(5) do
      write_shared_memory(circuit_name, {
        status: status,
        opened_at: opened_at,
        updated_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
      })
    end
  end

  def record_success(circuit_name, duration)
    with_timeout(2) do
      increment_counter(circuit_name, :success)
    end
  end

  def record_failure(circuit_name, duration)
    with_timeout(2) do
      increment_counter(circuit_name, :failure)
    end
  end

  def success_count(circuit_name, window_seconds)
    with_timeout(2) do
      count_events(circuit_name, :success, window_seconds)
    end
  end

  def failure_count(circuit_name, window_seconds)
    with_timeout(2) do
      count_events(circuit_name, :failure, window_seconds)
    end
  end

  def clear(circuit_name)
    with_timeout(5) do
      clear_shared_memory(circuit_name)
    end
  end

  def clear_all
    with_timeout(10) do
      clear_all_shared_memory
    end
  end

  private

  def generate_semaphore_key
    # Generate unique key based on process info
    File.basename($0).hash & 0xFFFF
  end

  def read_shared_memory(circuit_name)
    # Implementation depends on your shared memory strategy
    # Could use mmap, sysv shared memory, etc.
  end

  def write_shared_memory(circuit_name, data)
    # Implementation depends on your shared memory strategy
  end

  def increment_counter(circuit_name, type)
    # Atomic increment in shared memory
  end

  def count_events(circuit_name, type, window)
    # Count events within time window from shared memory
  end
end

# Use in fallback chain
circuit :shopify_style do
  storage :fallback_chain, {
    primary: { backend: :cache, timeout: 5 },
    fallback: { backend: SysVSemaphoreStorage, timeout: 2 },
    final: { backend: :null, timeout: 1 }
  }
end
```

**Note:** SysV semaphores are platform-specific (Linux/Unix) and require careful resource management. Always ensure proper cleanup on process termination.

#### MongoDB Storage Example

```ruby
class MongoDBStorage < BreakerMachines::Storage::Base
  def initialize(options = {})
    @collection = options[:collection] || MongoDB.client[:circuits]
    super
  end

  def increment_failure(circuit_name)
    @collection.update_one(
      { name: circuit_name },
      {
        '$inc' => { failures: 1 },
        '$set' => { last_failure: Time.now }
      },
      upsert: true
    )
  end

  def failure_count(circuit_name, window:)
    doc = @collection.find(name: circuit_name).first
    return 0 unless doc

    # Count failures within window
    return 0 if doc[:last_failure] < window.ago
    doc[:failures]
  end

  def reset(circuit_name)
    @collection.update_one(
      { name: circuit_name },
      { '$set' => { failures: 0, state: 'closed' } }
    )
  end

  def get_state(circuit_name)
    doc = @collection.find(name: circuit_name).first
    doc ? doc[:state] : 'closed'
  end

  def set_state(circuit_name, state)
    @collection.update_one(
      { name: circuit_name },
      { '$set' => { state: state, updated_at: Time.now } },
      upsert: true
    )
  end
end

# Use custom storage
circuit :mongodb_backed do
  storage MongoDBStorage.new(collection: db[:circuits])
  threshold failures: 5, within: 2.minutes
end
```

## State Synchronization Strategies

### Optimistic Synchronization

Default behavior - instances check shared state before making decisions:

```ruby
circuit :optimistic do
  storage :cache
  threshold failures: 3, within: 60.seconds

  # Each instance checks shared state on each call
  # Small race conditions possible but generally safe
end
```

### Pessimistic Synchronization

Use distributed locks for critical operations:

```ruby
class LockedCircuit
  include BreakerMachines::DSL

  circuit :critical do
    storage :cache
    threshold failures: 1, within: 30.seconds

    on_before_transition do |from, to|
      # Acquire distributed lock before state changes
      Redis.current.with_lock("circuit:critical:transition", ttl: 5) do
        # State transition happens here
      end
    end
  end
end
```

### Event-Based Synchronization

Broadcast state changes to all instances:

```ruby
class BroadcastCircuit
  include BreakerMachines::DSL

  circuit :broadcast do
    storage :cache

    on_open do
      # Notify all instances
      Redis.current.publish("circuits", {
        name: :broadcast,
        state: :open,
        timestamp: Time.now
      }.to_json)
    end
  end
end

# Subscriber (in initializer)
Thread.new do
  Redis.current.subscribe("circuits") do |on|
    on.message do |channel, message|
      data = JSON.parse(message)
      # Update local circuit state cache
      BreakerMachines.registry.sync_state(
        data['name'],
        data['state']
      )
    end
  end
end
```

## Persistence Patterns

### High Availability Setup

```ruby
# Primary storage with fallback
class HACircuit
  include BreakerMachines::DSL

  circuit :ha_service do
    storage :cache, cache_store: primary_redis

    # Fallback to secondary if primary fails
    on_storage_error do |error|
      self.storage = :cache, cache_store: secondary_redis
      notify_ops("Primary Redis failed: #{error}")
    end
  end

  private

  def primary_redis
    # Your primary Redis connection
  end

  def secondary_redis
    # Your secondary Redis connection
  end

  def notify_ops(message)
    # Your notification implementation
  end
end
```

### State Export/Import

```ruby
# Export circuit states for backup/migration
module CircuitStateManager
  def self.export_all
    BreakerMachines.registry.all.map do |name, circuit|
      {
        name: name,
        state: circuit.state,
        failure_count: circuit.failure_count,
        last_failure: circuit.last_failure_time,
        config: circuit.config
      }
    end
  end

  def self.import_states(states)
    states.each do |state_data|
      circuit = BreakerMachines.registry.get(state_data[:name])
      next unless circuit

      circuit.restore_state(
        state: state_data[:state],
        failure_count: state_data[:failure_count],
        last_failure: state_data[:last_failure]
      )
    end
  end
end

# Usage
states = CircuitStateManager.export_all
File.write('circuit_states.json', states.to_json)

# Later...
states = JSON.parse(File.read('circuit_states.json'))
CircuitStateManager.import_states(states)
```

## Performance Considerations

### Caching Strategies

```ruby
class CachedStateCircuit
  include BreakerMachines::DSL

  circuit :cached do
    storage :cache

    # Cache state locally for 1 second
    # Reduces Redis calls in high-traffic scenarios
    state_cache_ttl 1.second
  end
end
```

### Batch Operations

```ruby
class BatchCircuit
  include BreakerMachines::DSL

  circuit :batch do
    storage :cache

    # Batch failure increments
    batch_increment_failures do |failures|
      # Custom logic to batch write failures
      # Reduces storage backend calls
    end
  end
end
```

## Multi-Region Considerations

### Region-Aware Circuits

```ruby
class RegionalCircuit
  include BreakerMachines::DSL

  circuit :regional_service do
    # Use region-specific storage
    storage :cache, cache_store: regional_redis

    # Region-specific thresholds
    threshold failures: region_threshold, within: 1.minute
  end

  private

  def regional_redis
    case current_region
    when 'us-east'
      Redis.new(url: ENV['US_EAST_REDIS_URL'])
    when 'eu-west'
      Redis.new(url: ENV['EU_WEST_REDIS_URL'])
    else
      Redis.current
    end
  end

  def region_threshold
    # Higher thresholds for regions with less stable infrastructure
    case current_region
    when 'us-east' then 3
    when 'eu-west' then 3
    when 'ap-south' then 5  # Less stable
    else 3
    end
  end

  def current_region
    # Your region detection logic
    ENV['AWS_REGION'] || 'us-east'
  end
end
```

### Cross-Region Synchronization

```ruby
class GlobalCircuit
  include BreakerMachines::DSL

  circuit :global_service do
    storage :cache

    # Sync state across regions on state change
    on_state_change do |from, to|
      sync_to_regions(to) if significant_transition?(from, to)
    end
  end

  private

  def significant_transition?(from, to)
    # Only sync open/close transitions
    (from == :closed && to == :open) ||
    (from == :open && to == :closed)
  end

  def sync_to_regions(state)
    regions = ['us-west', 'eu-west', 'ap-south']

    regions.each do |region|
      RegionSync.perform_async(
        circuit: :global_service,
        state: state,
        region: region
      )
    end
  end
end
```

## Best Practices

1. **Choose the Right Storage**: Use memory for single-instance apps, cache for distributed systems
2. **Monitor Storage Latency**: Track how storage operations affect circuit performance
3. **Plan for Failures**: Always have a fallback plan if your storage backend fails
4. **Consider Consistency**: Decide if eventual consistency is acceptable for your use case
5. **Test State Persistence**: Ensure circuits maintain correct state across restarts

## Next Steps

- Set up [Monitoring and Observability](OBSERVABILITY.md)
- Learn about [Async Mode](ASYNC.md) for modern Ruby applications
- Explore [Rails Integration](RAILS_INTEGRATION.md) patterns