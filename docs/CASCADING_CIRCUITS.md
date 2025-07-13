# Cascading Circuit Breakers

Cascading circuit breakers allow you to model complex system dependencies where the failure of one critical system automatically trips dependent systems. This is particularly useful for modeling infrastructure where certain components depend on others to function properly.

## Overview

When a cascading circuit breaker opens (fails), it automatically forces all its dependent circuits to open as well. This prevents cascading failures from propagating through your system in an uncontrolled manner.

## Basic Usage

```ruby
class PowerGrid
  include BreakerMachines::DSL

  # Define a cascading circuit
  cascade_circuit :main_power do
    threshold failures: 3, within: 60.seconds
    cascades_to :lighting, :hvac, :elevators
    emergency_protocol :backup_generator_start
  end

  # Define dependent circuits
  circuit :lighting do
    threshold failures: 10, within: 60.seconds
  end

  circuit :hvac do
    threshold failures: 5, within: 60.seconds
  end

  circuit :elevators do
    threshold failures: 5, within: 60.seconds
  end

  # Emergency protocol method
  def backup_generator_start(affected_circuits)
    puts "Starting backup generator for: #{affected_circuits.join(', ')}"
  end
end
```

## Configuration Options

### cascades_to

Specifies which circuits should be tripped when this circuit opens:

```ruby
cascade_circuit :database do
  cascades_to :user_service, :order_service, :inventory_service
end
```

### emergency_protocol

Defines a method to be called when cascading occurs:

```ruby
cascade_circuit :network do
  emergency_protocol :switch_to_offline_mode
end

def switch_to_offline_mode(affected_circuits)
  # Handle the cascade event
  affected_circuits.each do |circuit|
    enable_offline_mode_for(circuit)
  end
end
```

### on_cascade

Provides a block to be executed during cascade:

```ruby
cascade_circuit :api_gateway do
  on_cascade do |affected_circuits|
    Rails.logger.error "API Gateway failure cascaded to: #{affected_circuits}"
    notify_ops_team(affected_circuits)
  end
end
```

## Real-World Examples

### Microservices Architecture

```ruby
class APIGateway
  include BreakerMachines::DSL

  cascade_circuit :authentication_service do
    threshold failures: 5, within: 30.seconds
    cascades_to :user_api, :admin_api, :mobile_api
    emergency_protocol :enable_read_only_mode

    on_cascade do |affected|
      MetricsCollector.record_cascade(:auth_service, affected)
    end
  end

  cascade_circuit :database_master do
    threshold failures: 3, within: 10.seconds
    cascades_to :write_endpoints, :sync_service
    emergency_protocol :failover_to_replica
  end
end
```

### Infrastructure Management

```ruby
class DataCenter
  include BreakerMachines::DSL

  cascade_circuit :cooling_system do
    threshold failures: 2, within: 5.minutes
    cascades_to :server_rack_a, :server_rack_b, :server_rack_c
    emergency_protocol :emergency_shutdown

    on_cascade do |affected|
      send_alert("Cooling failure! Shutting down: #{affected}")
    end
  end

  cascade_circuit :primary_power do
    threshold failures: 1, within: 1.second
    cascades_to :cooling_system, :network_switches, :storage_arrays
    emergency_protocol :switch_to_ups
  end
end
```

### E-commerce Platform

```ruby
class EcommercePlatform
  include BreakerMachines::DSL

  cascade_circuit :payment_gateway do
    threshold failures: 10, within: 60.seconds
    cascades_to :checkout_service, :subscription_service
    emergency_protocol :queue_transactions

    fallback { { status: 'queued', message: 'Payment will be processed shortly' } }
  end

  cascade_circuit :inventory_database do
    threshold failures: 5, within: 30.seconds
    cascades_to :product_api, :search_service, :recommendation_engine
    emergency_protocol :use_cached_inventory
  end

  def queue_transactions(affected_circuits)
    Redis.current.lpush('payment_queue', pending_transactions)
    notify_customers("Payments are being queued due to temporary issues")
  end

  def use_cached_inventory(affected_circuits)
    Rails.cache.write('inventory_mode', 'cached')
    affected_circuits.each do |circuit|
      invalidate_realtime_features(circuit)
    end
  end
end
```

## Testing Cascading Circuits

```ruby
class CascadeTest < ActiveSupport::TestCase
  test "main system failure cascades to dependents" do
    system = PowerSystem.new

    # Verify all circuits start closed
    assert system.circuit(:main_power).closed?
    assert system.circuit(:subsystem_a).closed?
    assert system.circuit(:subsystem_b).closed?

    # Trigger main power failures
    3.times do
      system.circuit(:main_power).call { raise "Power failure!" }
    rescue
      # Expected
    end

    # Verify cascade occurred
    assert system.circuit(:main_power).open?
    assert system.circuit(:subsystem_a).open?
    assert system.circuit(:subsystem_b).open?
  end

  test "emergency protocol is triggered on cascade" do
    system = PowerSystem.new
    emergency_called = false

    system.define_singleton_method(:emergency_shutdown) do |circuits|
      emergency_called = true
    end

    # Trigger cascade
    3.times do
      system.circuit(:main_power).call { raise "Failure!" }
    rescue
      # Expected
    end

    assert emergency_called
  end
end
```

## Best Practices

### 1. Design Clear Dependencies

Map out your system dependencies before implementing cascading circuits:

```ruby
# Good: Clear hierarchy
cascade_circuit :database do
  cascades_to :api, :background_jobs
end

cascade_circuit :api do
  cascades_to :web_frontend, :mobile_app
end
```

### 2. Implement Graceful Degradation

Always provide fallbacks for cascaded services:

```ruby
circuit :user_service do
  fallback { { users: [], status: 'degraded' } }
end
```

### 3. Use Emergency Protocols Wisely

Emergency protocols should focus on mitigation, not recovery:

```ruby
def emergency_protocol(affected_circuits)
  # Good: Mitigation
  switch_to_read_only_mode
  queue_write_operations
  notify_users_of_degradation

  # Avoid: Attempting immediate recovery
  # affected_circuits.each { |c| circuit(c).reset! }
end
```

### 4. Monitor Cascade Events

Track cascade events for system health monitoring:

```ruby
on_cascade do |affected_circuits|
  StatsD.increment('circuit.cascade', tags: ["source:#{@name}"])
  affected_circuits.each do |circuit|
    StatsD.increment('circuit.cascaded', tags: ["circuit:#{circuit}"])
  end
end
```

### 5. Test Cascade Scenarios

Always test both the cascade trigger and recovery:

```ruby
test "system recovers after cascade" do
  # Trigger cascade
  trigger_main_system_failure

  # Reset main system
  system.circuit(:main).reset!

  # Dependent systems remain open (intentional)
  assert system.circuit(:dependent).open?

  # Must explicitly reset cascaded circuits
  system.circuit(:dependent).reset!
  assert system.circuit(:dependent).closed?
end
```

## Advanced Patterns

### Multi-Level Cascades

```ruby
# Level 1: Infrastructure
cascade_circuit :data_center_power do
  cascades_to :server_power, :network_power
end

# Level 2: Hardware
cascade_circuit :server_power do
  cascades_to :application_servers, :database_servers
end

# Level 3: Services
cascade_circuit :application_servers do
  cascades_to :web_service, :api_service
end
```

### Conditional Cascades

```ruby
cascade_circuit :primary_database do
  on_cascade do |affected_circuits|
    if business_hours?
      # Full cascade during business hours
      force_open_circuits(affected_circuits)
    else
      # Partial cascade during off-hours
      force_open_circuits(affected_circuits.select { |c| critical?(c) })
    end
  end
end
```

### Cascade with Recovery Priority

```ruby
class SystemWithPriority
  include BreakerMachines::DSL

  RECOVERY_PRIORITY = {
    critical: [:authentication, :database],
    high: [:api, :web],
    medium: [:analytics, :reporting],
    low: [:recommendations, :notifications]
  }.freeze

  def recover_from_cascade
    RECOVERY_PRIORITY.each do |priority, circuits|
      circuits.each do |circuit_name|
        begin
          circuit(circuit_name).reset! if circuit(circuit_name).open?
          Rails.logger.info "Recovered #{circuit_name} (#{priority} priority)"
          sleep 0.5 # Gradual recovery
        rescue => e
          Rails.logger.error "Failed to recover #{circuit_name}: #{e.message}"
        end
      end
    end
  end
end
```

## Limitations and Considerations

1. **Cascade Direction**: Cascades are unidirectional. Child circuits failing does not affect parent circuits.

2. **Reset Behavior**: Cascaded circuits must be manually reset. They don't automatically recover when the parent circuit recovers.

3. **Performance Impact**: Large cascade chains can impact performance. Design your cascade hierarchy carefully.

4. **Circular Dependencies**: The system doesn't prevent circular dependencies. Avoid them in your design:
   ```ruby
   # Bad: Circular dependency
   cascade_circuit :service_a do
     cascades_to :service_b
   end

   cascade_circuit :service_b do
     cascades_to :service_a  # Creates a cycle!
   end
   ```

5. **Instance vs Global**: Cascading works within instance boundaries. Cross-instance cascading requires additional coordination.

## Integration with Monitoring

```ruby
class MonitoredCascadingSystem
  include BreakerMachines::DSL

  cascade_circuit :critical_service do
    cascades_to :dependent_a, :dependent_b

    on_cascade do |affected|
      # Log to monitoring system
      AppMonitor.event('cascade.triggered',
        source: 'critical_service',
        affected: affected,
        severity: 'high'
      )

      # Create incident if needed
      if affected.size > 3
        IncidentManager.create(
          title: "Major cascade from critical_service",
          affected_systems: affected
        )
      end
    end
  end
end
```

## Summary

Cascading circuit breakers provide a powerful way to model system dependencies and handle failures in a controlled manner. They're particularly valuable in:

- Microservices architectures
- Infrastructure management
- Multi-tier applications
- Systems with clear dependency hierarchies

By automatically propagating failures to dependent systems and triggering emergency protocols, cascading circuits help prevent partial failures from causing inconsistent system states.
