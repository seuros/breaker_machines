# Coordinated State Management

Coordinated state management extends circuit breakers with dependency-aware state transitions, leveraging state_machines' guard features. This allows circuits to make intelligent decisions about state transitions based on the health of other circuits.

## Overview

With coordinated state management, circuits can:
- Check dependencies before attempting recovery
- Prevent resets when critical dependencies are down
- Coordinate state transitions across related circuits
- Implement complex recovery strategies

## How It Works

The `CoordinatedCircuit` class uses guard conditions on state transitions:

```ruby
state_machine :status, initial: :closed do
  event :attempt_recovery do
    transition open: :half_open,
               if: ->(circuit) { circuit.recovery_allowed? }
  end

  event :reset do
    transition %i[open half_open] => :closed,
               if: ->(circuit) { circuit.reset_allowed? }
  end
end
```

## Basic Usage

### Using CoordinatedCircuit Directly

```ruby
class PaymentProcessor
  def initialize
    @database = BreakerMachines::CoordinatedCircuit.new('payment_db', {
      failure_threshold: 3,
      reset_timeout: 30.seconds
    })

    @payment_gateway = BreakerMachines::CoordinatedCircuit.new('payment_gateway', {
      failure_threshold: 5,
      reset_timeout: 60.seconds
    })
    
    # Payment gateway depends on database
    @payment_gateway.dependent_circuits = [:payment_db]
  end

  def process_payment(amount)
    @payment_gateway.call do
      # This will fail if database circuit is open
      PaymentAPI.charge(amount)
    end
  end
end
```

### With CascadingCircuit

`CascadingCircuit` now inherits from `CoordinatedCircuit`, providing both cascading and coordination features:

```ruby
class InfrastructureManager
  include BreakerMachines::DSL

  cascade_circuit :main_database do
    threshold failures: 3
    cascades_to :cache_layer, :search_index
    
    # Main database won't attempt recovery if backup is down
    dependent_circuits [:backup_database]
  end

  cascade_circuit :backup_database do
    threshold failures: 5
    # Backup can recover independently
  end
end
```

## Recovery Coordination

### Automatic Recovery Prevention

Circuits won't attempt recovery when dependencies are unhealthy:

```ruby
# Setup dependent circuits
primary = BreakerMachines::CoordinatedCircuit.new('primary_service')
secondary = BreakerMachines::CoordinatedCircuit.new('secondary_service')
secondary.dependent_circuits = [:primary_service]

# Register circuits so they can find each other
BreakerMachines.register(primary)
BreakerMachines.register(secondary)

# If primary is open, secondary won't recover
primary.force_open!
secondary.force_open!

# This returns false - recovery not allowed
secondary.can_attempt_recovery? # => false

# Once primary recovers, secondary can attempt recovery
primary.reset!
secondary.can_attempt_recovery? # => true
```

### Custom Recovery Logic

Override `recovery_allowed?` for custom logic:

```ruby
class SmartCircuit < BreakerMachines::CoordinatedCircuit
  def recovery_allowed?
    return false unless super
    
    # Additional custom checks
    return false if maintenance_mode?
    return false if peak_traffic?
    return false unless minimum_resources_available?
    
    true
  end

  private

  def maintenance_mode?
    Redis.current.get('maintenance_mode') == 'true'
  end

  def peak_traffic?
    (9..17).include?(Time.current.hour) && !weekend?
  end

  def minimum_resources_available?
    cpu_usage < 80 && memory_available > 1.gigabyte
  end
end
```

## Reset Coordination

### Preventing Unsafe Resets

Circuits check dependencies before allowing manual resets:

```ruby
# API depends on both database and cache
api_circuit = BreakerMachines::CoordinatedCircuit.new('api')
api_circuit.dependent_circuits = [:database, :cache]

# If either dependency is down, reset is not allowed
database_circuit.force_open!

api_circuit.reset! # => false (no-op, won't reset)
api_circuit.open? # => true (still open)

# Fix dependencies first
database_circuit.reset!
cache_circuit.reset!

# Now API can reset
api_circuit.reset! # => true
api_circuit.closed? # => true
```

### Custom Reset Logic

Override `reset_allowed?` for custom reset conditions:

```ruby
class DataProcessingCircuit < BreakerMachines::CoordinatedCircuit
  def reset_allowed?
    return false unless super
    
    # Don't reset if we have pending work
    return false if pending_jobs_count > 0
    
    # Don't reset during data migration
    return false if migration_in_progress?
    
    true
  end

  private

  def pending_jobs_count
    Sidekiq::Queue.new('data_processing').size
  end

  def migration_in_progress?
    Redis.current.get('data_migration:status') == 'running'
  end
end
```

## Real-World Examples

### Database Cluster Management

```ruby
class DatabaseCluster
  def initialize
    # Primary database
    @primary = BreakerMachines::CoordinatedCircuit.new('db_primary', {
      failure_threshold: 3,
      reset_timeout: 60.seconds
    })

    # Read replicas depend on primary
    @replica1 = create_replica_circuit('db_replica1')
    @replica2 = create_replica_circuit('db_replica2')
    
    # Cache depends on primary being healthy
    @cache = BreakerMachines::CoordinatedCircuit.new('db_cache', {
      failure_threshold: 10,
      reset_timeout: 30.seconds
    })
    @cache.dependent_circuits = [:db_primary]
    
    register_all_circuits
  end

  private

  def create_replica_circuit(name)
    circuit = BreakerMachines::CoordinatedCircuit.new(name, {
      failure_threshold: 5,
      reset_timeout: 45.seconds
    })
    circuit.dependent_circuits = [:db_primary]
    circuit
  end

  def register_all_circuits
    [@primary, @replica1, @replica2, @cache].each do |circuit|
      BreakerMachines.register(circuit)
    end
  end

  public

  def execute_query(query, options = {})
    if options[:write] || options[:strong_consistency]
      @primary.call { run_on_primary(query) }
    else
      # Try replicas first, fall back to primary
      load_balanced_read(query)
    end
  end

  def load_balanced_read(query)
    replicas = [@replica1, @replica2].select(&:closed?)
    
    if replicas.any?
      replica = replicas.sample
      replica.call { run_on_replica(query, replica) }
    else
      # Fall back to primary
      @primary.call { run_on_primary(query) }
    end
  end

  def health_status
    {
      primary: @primary.status_name,
      replicas: {
        replica1: @replica1.status_name,
        replica2: @replica2.status_name
      },
      cache: @cache.status_name,
      can_write: @primary.closed?,
      can_read: [@primary, @replica1, @replica2].any?(&:closed?)
    }
  end
end
```

### Service Mesh Integration

```ruby
class ServiceMeshCircuitManager
  def initialize
    @circuits = {}
    setup_service_dependencies
  end

  private

  def setup_service_dependencies
    # Core infrastructure
    create_circuit('consul', dependencies: [])
    create_circuit('vault', dependencies: [:consul])
    
    # Platform services
    create_circuit('auth_service', dependencies: [:consul, :vault])
    create_circuit('config_service', dependencies: [:consul])
    
    # Business services
    create_circuit('user_service', dependencies: [:auth_service, :config_service])
    create_circuit('order_service', dependencies: [:auth_service, :config_service])
    create_circuit('payment_service', dependencies: [:auth_service, :vault])
    
    # API Gateway depends on all business services
    create_circuit('api_gateway', dependencies: [
      :user_service, :order_service, :payment_service
    ])
  end

  def create_circuit(name, dependencies:)
    circuit = BreakerMachines::CoordinatedCircuit.new(name.to_s, {
      failure_threshold: threshold_for_service(name),
      reset_timeout: timeout_for_service(name)
    })
    
    circuit.dependent_circuits = dependencies
    BreakerMachines.register(circuit)
    @circuits[name] = circuit
  end

  def threshold_for_service(name)
    case name
    when :consul, :vault then 2  # Critical infrastructure
    when :auth_service then 3     # Important platform service
    when :api_gateway then 10     # User-facing, more tolerant
    else 5                        # Default
    end
  end

  def timeout_for_service(name)
    case name
    when :consul, :vault then 10.seconds  # Quick recovery for critical
    when :api_gateway then 60.seconds     # Slower for user-facing
    else 30.seconds                       # Default
    end
  end

  public

  def call_service(name, &block)
    circuit = @circuits[name]
    raise "Unknown service: #{name}" unless circuit
    
    circuit.call(&block)
  rescue BreakerMachines::CircuitOpenError => e
    handle_circuit_open(name, e)
  end

  def handle_circuit_open(service, error)
    Rails.logger.error("Circuit open for #{service}: #{error.message}")
    
    # Check why it might be open
    if circuit = @circuits[service]
      deps = circuit.dependent_circuits
      down_deps = deps.select { |d| @circuits[d]&.open? }
      
      if down_deps.any?
        raise "Service #{service} unavailable due to dependencies: #{down_deps.join(', ')}"
      else
        raise "Service #{service} is experiencing issues"
      end
    end
  end

  def recovery_order
    # Determine safe recovery order based on dependencies
    ordered = []
    remaining = @circuits.keys
    
    while remaining.any?
      # Find services with no remaining dependencies
      ready = remaining.select do |service|
        deps = @circuits[service].dependent_circuits
        deps.empty? || deps.all? { |d| ordered.include?(d) }
      end
      
      break if ready.empty? # Circular dependency
      
      ordered.concat(ready.sort)
      remaining -= ready
    end
    
    ordered
  end

  def orchestrated_recovery
    recovery_order.each do |service|
      circuit = @circuits[service]
      next unless circuit.open?
      
      if circuit.recovery_allowed?
        Rails.logger.info("Attempting recovery for #{service}")
        circuit.attempt_recovery!
        sleep 0.5 # Gradual recovery
      else
        Rails.logger.info("Skipping #{service} - dependencies not ready")
      end
    end
  end
end
```

### Multi-Stage Processing Pipeline

```ruby
class DataPipeline
  def initialize
    # Stage 1: Data ingestion
    @ingestion = BreakerMachines::CoordinatedCircuit.new('ingestion', {
      failure_threshold: 10,
      reset_timeout: 30.seconds
    })

    # Stage 2: Validation (depends on ingestion)
    @validation = BreakerMachines::CoordinatedCircuit.new('validation', {
      failure_threshold: 5,
      reset_timeout: 45.seconds
    })
    @validation.dependent_circuits = [:ingestion]

    # Stage 3: Processing (depends on validation)
    @processing = BreakerMachines::CoordinatedCircuit.new('processing', {
      failure_threshold: 3,
      reset_timeout: 60.seconds
    })
    @processing.dependent_circuits = [:validation]

    # Stage 4: Storage (depends on processing)
    @storage = BreakerMachines::CoordinatedCircuit.new('storage', {
      failure_threshold: 2,
      reset_timeout: 90.seconds
    })
    @storage.dependent_circuits = [:processing]

    register_all_stages
  end

  def process_data(data)
    # Each stage depends on the previous one
    ingested = @ingestion.call { ingest_data(data) }
    validated = @validation.call { validate_data(ingested) }
    processed = @processing.call { process_data(validated) }
    @storage.call { store_results(processed) }
  rescue BreakerMachines::CircuitOpenError, BreakerMachines::CircuitDependencyError => e
    handle_pipeline_failure(e, data)
  end

  private

  def handle_pipeline_failure(error, data)
    # Determine which stage failed
    failed_stage = detect_failed_stage
    
    # Queue for retry when pipeline recovers
    RetryQueue.push(
      data: data,
      failed_at: failed_stage,
      error: error.message,
      retry_after: Time.current + 5.minutes
    )
    
    Rails.logger.error("Pipeline failed at #{failed_stage}: #{error.message}")
  end

  def detect_failed_stage
    return :storage if @storage.open?
    return :processing if @processing.open?
    return :validation if @validation.open?
    return :ingestion if @ingestion.open?
    :unknown
  end

  def register_all_stages
    [@ingestion, @validation, @processing, @storage].each do |circuit|
      BreakerMachines.register(circuit)
    end
  end
end
```

## Testing Coordinated Circuits

### Testing Recovery Guards

```ruby
require 'test_helper'

class CoordinatedCircuitTest < ActiveSupport::TestCase
  def setup
    @primary = BreakerMachines::CoordinatedCircuit.new('primary', {
      failure_threshold: 1,
      reset_timeout: 0.1
    })
    
    @dependent = BreakerMachines::CoordinatedCircuit.new('dependent', {
      failure_threshold: 1,
      reset_timeout: 0.1
    })
    @dependent.dependent_circuits = [:primary]
    
    BreakerMachines.register(@primary)
    BreakerMachines.register(@dependent)
  end

  test "dependent circuit cannot recover when dependency is open" do
    # Break both circuits
    [@primary, @dependent].each do |circuit|
      assert_raises(StandardError) do
        circuit.call { raise "Error" }
      end
    end
    
    assert @primary.open?
    assert @dependent.open?
    
    # Wait for reset timeout
    sleep 0.2
    
    # Dependent should not auto-recover
    refute @dependent.reset_timeout_elapsed?
    refute @dependent.recovery_allowed?
    
    # Primary can recover
    assert @primary.recovery_allowed?
    @primary.attempt_recovery!
    assert @primary.half_open?
    
    # Now dependent can attempt recovery
    assert @dependent.recovery_allowed?
  end

  test "reset not allowed when dependencies are down" do
    # Break primary
    assert_raises(StandardError) do
      @primary.call { raise "Error" }
    end
    
    # Force dependent open
    @dependent.force_open!
    
    # Try to reset dependent
    refute @dependent.reset_allowed?
    @dependent.reset! # No-op
    assert @dependent.open? # Still open
    
    # Fix primary
    @primary.reset!
    
    # Now reset works
    assert @dependent.reset_allowed?
    @dependent.reset!
    assert @dependent.closed?
  end
end
```

### Testing Complex Dependencies

```ruby
class ComplexCoordinationTest < ActiveSupport::TestCase
  def setup
    # Create a dependency graph:
    # A -> B -> C
    #   -> D -> E
    
    @circuits = {}
    create_circuit(:a, dependencies: [])
    create_circuit(:b, dependencies: [:a])
    create_circuit(:c, dependencies: [:b])
    create_circuit(:d, dependencies: [:a])
    create_circuit(:e, dependencies: [:d])
  end

  def create_circuit(name, dependencies:)
    circuit = BreakerMachines::CoordinatedCircuit.new(name.to_s, {
      failure_threshold: 1
    })
    circuit.dependent_circuits = dependencies
    BreakerMachines.register(circuit)
    @circuits[name] = circuit
  end

  test "cascading dependency failures" do
    # Break root circuit
    assert_raises(StandardError) do
      @circuits[:a].call { raise "Error" }
    end
    
    # All dependent circuits should not be recoverable
    [:b, :c, :d, :e].each do |name|
      @circuits[name].force_open!
      refute @circuits[name].recovery_allowed?,
             "#{name} should not be recoverable"
    end
    
    # Fix root
    @circuits[:a].reset!
    
    # Direct dependencies can recover
    assert @circuits[:b].recovery_allowed?
    assert @circuits[:d].recovery_allowed?
    
    # But transitive dependencies still can't
    refute @circuits[:c].recovery_allowed?
    refute @circuits[:e].recovery_allowed?
  end
end
```

## Best Practices

### 1. Model Real Dependencies

Only model dependencies that reflect actual system requirements:

```ruby
# Good: Real infrastructure dependency
cache_circuit.dependent_circuits = [:redis_cluster]

# Bad: Artificial dependency
report_service.dependent_circuits = [:email_service]  # Reports work without email
```

### 2. Avoid Circular Dependencies

The system doesn't prevent circular dependencies, so design carefully:

```ruby
# Bad: Circular dependency
auth_service.dependent_circuits = [:user_service]
user_service.dependent_circuits = [:auth_service]

# Good: Clear hierarchy
database.dependent_circuits = []
user_service.dependent_circuits = [:database]
auth_service.dependent_circuits = [:user_service]
```

### 3. Implement Graceful Degradation

Services should handle dependency failures gracefully:

```ruby
def get_user_preferences(user_id)
  preferences_circuit.call { 
    PreferencesService.get(user_id) 
  }
rescue BreakerMachines::CircuitDependencyError
  # Return defaults when dependencies are down
  UserPreferences.defaults_for(user_id)
end
```

### 4. Monitor Coordination Events

Track when coordination prevents operations:

```ruby
class InstrumentedCoordinatedCircuit < BreakerMachines::CoordinatedCircuit
  def recovery_allowed?
    allowed = super
    
    unless allowed
      StatsD.increment('circuit.recovery_blocked', 
                      tags: ["circuit:#{name}"])
    end
    
    allowed
  end

  def reset_allowed?
    allowed = super
    
    unless allowed
      StatsD.increment('circuit.reset_blocked',
                      tags: ["circuit:#{name}"])
    end
    
    allowed
  end
end
```

### 5. Document Dependencies

Keep dependency relationships well-documented:

```ruby
# Dependencies:
# - database (primary PostgreSQL cluster)
# - cache (Redis cluster) - depends on: database
# - auth_service - depends on: database
# - user_service - depends on: database, cache
# - api_gateway - depends on: auth_service, user_service

class ServiceConfiguration
  DEPENDENCY_GRAPH = {
    database: [],
    cache: [:database],
    auth_service: [:database],
    user_service: [:database, :cache],
    api_gateway: [:auth_service, :user_service]
  }.freeze
end
```

## Performance Considerations

1. **Dependency Checks**: Dependency checking is performed on each state transition attempt. Keep dependency chains shallow for better performance.

2. **Circuit Registry**: The global registry enables circuits to find their dependencies. In high-throughput scenarios, consider caching dependency lookups.

3. **Recovery Checks**: The `reset_timeout_elapsed?` check includes dependency validation. This is lightweight but runs periodically.

## Summary

Coordinated state management provides intelligent circuit breaker behavior by:

- Preventing recovery attempts when dependencies are unhealthy
- Blocking resets that would leave the system in an inconsistent state
- Enabling sophisticated recovery orchestration
- Supporting complex service dependency graphs

This feature is essential for building resilient distributed systems where service health is interconnected and recovery must be carefully orchestrated.