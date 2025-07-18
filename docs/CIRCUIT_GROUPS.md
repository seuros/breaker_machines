# Circuit Groups

Circuit groups provide coordinated management of multiple related circuits with support for dependencies, shared configuration, and group-wide operations. This feature leverages state_machines' coordinated state management capabilities.

## Overview

Circuit groups allow you to:
- Define multiple circuits with shared configuration
- Establish dependencies between circuits
- Perform group-wide operations (reset all, trip all)
- Add custom guard conditions for circuit transitions
- Monitor group health status

## Basic Usage

```ruby
class MicroserviceStack
  include BreakerMachines::DSL

  def initialize
    @services = BreakerMachines::CircuitGroup.new('production_stack', {
      failure_threshold: 5,
      reset_timeout: 30.seconds
    })

    # Define circuits with dependencies
    @services.circuit :database do
      threshold failures: 3
    end

    @services.circuit :cache, depends_on: :database do
      threshold failures: 5
    end

    @services.circuit :api, depends_on: [:database, :cache] do
      threshold failures: 10
    end
  end

  def call_api(&block)
    @services[:api].call(&block)
  end
end
```

## Configuration Options

### Group-Level Configuration

Shared configuration applied to all circuits in the group:

```ruby
services = BreakerMachines::CircuitGroup.new('services', {
  failure_threshold: 10,
  reset_timeout: 60.seconds,
  storage: :memory,
  async_mode: true  # Use AsyncCircuit for all circuits
})
```

### Circuit Dependencies

Define dependencies between circuits using `depends_on`:

```ruby
services.circuit :auth_service, depends_on: :database do
  threshold failures: 5
end

services.circuit :api_gateway, depends_on: [:auth_service, :cache] do
  threshold failures: 10
end
```

### Custom Guards

Add custom guard conditions with `guard_with`:

```ruby
services.circuit :premium_features, 
                 depends_on: :payment_service,
                 guard_with: -> { feature_enabled?(:premium) } do
  threshold failures: 3
end
```

## Dependency Management

### How Dependencies Work

When a circuit has dependencies:
1. The circuit cannot be called if any dependency is in the `open` state
2. Dependency checks are recursive (transitive dependencies)
3. Custom guards are evaluated in addition to circuit state checks
4. A `CircuitDependencyError` is raised when dependencies aren't met

### Example: Transitive Dependencies

```ruby
services = BreakerMachines::CircuitGroup.new('stack')

# Database is the foundation
services.circuit :database do
  threshold failures: 1
end

# Cache depends on database
services.circuit :cache, depends_on: :database do
  threshold failures: 2
end

# API depends on cache (and transitively on database)
services.circuit :api, depends_on: :cache do
  threshold failures: 3
end

# If database fails, both cache and API become unavailable
```

## Group Operations

### Status Monitoring

```ruby
# Check if all circuits are healthy
if services.all_healthy?
  puts "All systems operational"
end

# Check if any circuit is open
if services.any_open?
  puts "System degraded"
end

# Get status of all circuits
status = services.status
# => { database: :closed, cache: :closed, api: :open }
```

### Bulk Operations

```ruby
# Reset all circuits to closed state
services.reset_all!

# Force all circuits to open state
services.trip_all!
```

## Real-World Examples

### E-Commerce Platform

```ruby
class EcommercePlatform
  def initialize
    @systems = BreakerMachines::CircuitGroup.new('ecommerce', {
      failure_threshold: 10,
      reset_timeout: 30.seconds
    })

    setup_infrastructure_layer
    setup_service_layer
    setup_api_layer
  end

  private

  def setup_infrastructure_layer
    @systems.circuit :postgres_primary do
      threshold failures: 3, within: 10.seconds
      timeout 5
    end

    @systems.circuit :redis_cache do
      threshold failures: 5, within: 30.seconds
      timeout 1
    end

    @systems.circuit :elasticsearch do
      threshold failures: 10, within: 60.seconds
      timeout 3
    end
  end

  def setup_service_layer
    @systems.circuit :user_service, depends_on: :postgres_primary do
      threshold failures: 5
      fallback { { users: [], status: 'degraded' } }
    end

    @systems.circuit :product_catalog, 
                     depends_on: [:postgres_primary, :elasticsearch] do
      threshold failures: 10
      fallback { cached_products }
    end

    @systems.circuit :cart_service, 
                     depends_on: [:redis_cache, :postgres_primary] do
      threshold failures: 7
    end
  end

  def setup_api_layer
    @systems.circuit :rest_api, 
                     depends_on: [:user_service, :product_catalog] do
      threshold failures: 20
    end

    @systems.circuit :graphql_api, 
                     depends_on: [:user_service, :product_catalog, :cart_service] do
      threshold failures: 15
    end
  end

  def health_check
    {
      healthy: @systems.all_healthy?,
      circuits: @systems.status,
      degraded_services: @systems.status.select { |_, status| status == :open }.keys
    }
  end
end
```

### Microservices with Feature Flags

```ruby
class FeatureAwarePlatform
  def initialize
    @features = BreakerMachines::CircuitGroup.new('features')
    
    # Core services
    @features.circuit :authentication do
      threshold failures: 5
    end

    # Feature-flagged services
    @features.circuit :recommendations,
                      depends_on: :authentication,
                      guard_with: -> { feature_enabled?(:recommendations) } do
      threshold failures: 10
      fallback { [] }
    end

    @features.circuit :real_time_analytics,
                      depends_on: :authentication,
                      guard_with: -> { feature_enabled?(:analytics) && peak_hours? } do
      threshold failures: 20
      fallback { { status: 'deferred' } }
    end
  end

  private

  def feature_enabled?(feature)
    FeatureFlag.enabled?(feature)
  end

  def peak_hours?
    (9..17).include?(Time.current.hour)
  end
end
```

### Multi-Region Architecture

```ruby
class MultiRegionService
  def initialize
    @regions = {
      us_east: create_region_group('us-east-1'),
      us_west: create_region_group('us-west-2'),
      eu_west: create_region_group('eu-west-1')
    }
  end

  private

  def create_region_group(region)
    group = BreakerMachines::CircuitGroup.new("region_#{region}")

    # Region-specific database
    group.circuit :regional_db do
      threshold failures: 5
      reset_after 60.seconds
    end

    # Services that depend on regional DB
    group.circuit :user_service, depends_on: :regional_db do
      threshold failures: 10
    end

    group.circuit :order_service, depends_on: :regional_db do
      threshold failures: 10
    end

    # Cross-region replication (can work without regional DB)
    group.circuit :replication_service do
      threshold failures: 20
      reset_after 120.seconds
    end

    group
  end

  def call_with_failover(region, service, &block)
    primary = @regions[region]
    
    begin
      primary[service].call(&block)
    rescue BreakerMachines::CircuitOpenError, BreakerMachines::CircuitDependencyError
      # Failover to another region
      failover_region = find_healthy_region(exclude: region)
      
      if failover_region
        Rails.logger.warn("Failing over from #{region} to #{failover_region}")
        @regions[failover_region][service].call(&block)
      else
        raise "All regions unavailable for #{service}"
      end
    end
  end

  def find_healthy_region(exclude:)
    @regions.except(exclude).find do |region, group|
      group.all_healthy?
    end&.first
  end
end
```

## Testing Circuit Groups

### Basic Testing

```ruby
require 'test_helper'

class CircuitGroupTest < ActiveSupport::TestCase
  def setup
    @group = BreakerMachines::CircuitGroup.new('test_group')
    
    @group.circuit :database do
      threshold failures: 1
    end
    
    @group.circuit :api, depends_on: :database do
      threshold failures: 2
    end
  end

  test "dependent circuit fails when dependency is open" do
    # Trip the database circuit
    assert_raises(StandardError) do
      @group[:database].call { raise "DB Error" }
    end
    
    assert @group[:database].open?
    
    # API should not be callable
    error = assert_raises(BreakerMachines::CircuitDependencyError) do
      @group[:api].call { "Should not execute" }
    end
    
    assert_match(/Dependencies not met/, error.message)
  end

  test "group operations affect all circuits" do
    # Trip all circuits
    @group.trip_all!
    
    assert @group[:database].open?
    assert @group[:api].open?
    assert @group.any_open?
    refute @group.all_healthy?
    
    # Reset all circuits
    @group.reset_all!
    
    assert @group[:database].closed?
    assert @group[:api].closed?
    assert @group.all_healthy?
  end
end
```

### Testing Complex Dependencies

```ruby
class ComplexDependencyTest < ActiveSupport::TestCase
  def setup
    @services = BreakerMachines::CircuitGroup.new('services')
    
    # Create a dependency chain
    @services.circuit :infrastructure do
      threshold failures: 1
    end
    
    @services.circuit :platform, depends_on: :infrastructure do
      threshold failures: 1
    end
    
    @services.circuit :api, depends_on: :platform do
      threshold failures: 1
    end
    
    @services.circuit :web, depends_on: :api do
      threshold failures: 1
    end
  end

  test "transitive dependencies are checked" do
    # Break infrastructure
    assert_raises(StandardError) do
      @services[:infrastructure].call { raise "Infrastructure down" }
    end
    
    # All dependent services should be affected
    [:platform, :api, :web].each do |service|
      assert_raises(BreakerMachines::CircuitDependencyError) do
        @services[service].call { "Should not run" }
      end
      
      # The circuits themselves are still closed
      assert @services[service].closed?
      
      # But dependencies are not met
      refute @services.dependencies_met?(service)
    end
  end
end
```

## Best Practices

### 1. Design Clear Dependency Hierarchies

Structure your dependencies to reflect actual system relationships:

```ruby
# Good: Clear layers
services.circuit :database
services.circuit :cache, depends_on: :database
services.circuit :service, depends_on: [:database, :cache]
services.circuit :api, depends_on: :service

# Avoid: Unclear relationships
services.circuit :service_a, depends_on: [:service_b, :service_c]
services.circuit :service_b, depends_on: :service_d
services.circuit :service_c, depends_on: [:service_d, :service_e]
```

### 2. Use Shared Configuration Wisely

Apply common settings at the group level:

```ruby
# Good: Shared defaults with specific overrides
services = BreakerMachines::CircuitGroup.new('services', {
  failure_threshold: 10,
  reset_timeout: 30.seconds,
  storage: :redis
})

services.circuit :critical_service do
  threshold failures: 3  # Override for critical service
  reset_after 10.seconds
end
```

### 3. Implement Gradual Recovery

When recovering from failures, bring services back gradually:

```ruby
def recover_services
  # Start with infrastructure
  @services[:database].reset! if @services[:database].open?
  sleep 1
  
  # Then dependent services
  [:cache, :user_service, :api].each do |service|
    if @services[service].open? && @services.dependencies_met?(service)
      @services[service].reset!
      sleep 0.5
    end
  end
end
```

### 4. Monitor Group Health

Use group status for health checks and monitoring:

```ruby
class HealthController < ApplicationController
  def show
    render json: {
      status: services_group.all_healthy? ? 'healthy' : 'degraded',
      services: services_group.status,
      dependencies_met: check_all_dependencies
    }
  end

  private

  def check_all_dependencies
    services_group.circuits.keys.map do |name|
      [name, services_group.dependencies_met?(name)]
    end.to_h
  end
end
```

### 5. Test Dependency Scenarios

Always test both failure and recovery scenarios:

```ruby
test "service recovery respects dependencies" do
  # Break everything
  break_database
  
  # Verify cascade effect
  assert @group[:database].open?
  assert_raises(BreakerMachines::CircuitDependencyError) do
    @group[:api].call { }
  end
  
  # Recover database
  @group[:database].reset!
  
  # API should now work
  assert_nothing_raised do
    @group[:api].call { "Works!" }
  end
end
```

## Integration with Async Operations

Circuit groups support async mode for fiber-safe operations:

```ruby
# Enable async mode for all circuits
async_services = BreakerMachines::CircuitGroup.new('async_services', 
                                                   async_mode: true)

async_services.circuit :async_api do
  threshold failures: 10
  timeout 5
end

# Use with async/await
Async do
  result = async_services[:async_api].call_async { 
    fetch_data_async 
  }.wait
end
```

## Performance Considerations

1. **Dependency Checks**: Dependency checking is recursive but lightweight. For deep dependency trees, consider caching dependency states.

2. **Group Size**: Large groups with many circuits are efficient, but consider splitting into logical sub-groups for better organization.

3. **Shared Storage**: All circuits in a group can share the same storage backend, reducing connection overhead.

## Summary

Circuit groups provide a powerful abstraction for managing related circuits with dependencies. They're particularly valuable for:

- Microservice architectures with service dependencies
- Multi-tier applications with clear architectural layers
- Systems requiring coordinated failure handling
- Applications with feature flags and conditional availability

By modeling dependencies explicitly and providing group-wide operations, circuit groups help ensure system consistency during partial failures and enable sophisticated failure handling strategies.