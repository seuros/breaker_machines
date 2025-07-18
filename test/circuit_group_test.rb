# frozen_string_literal: true

require 'test_helper'

class CircuitGroupTest < Minitest::Test
  def setup
    BreakerMachines.reset!
    BreakerMachines.config.default_storage = :memory
  end

  def test_basic_circuit_group
    starship_systems = BreakerMachines::CircuitGroup.new('enterprise', {
                                                           failure_threshold: 2,
                                                           reset_timeout: 0.1
                                                         })

    # Define circuits
    starship_systems.circuit :warp_core
    starship_systems.circuit :shields
    starship_systems.circuit :weapons

    # Access circuits
    assert_instance_of BreakerMachines::Circuit, starship_systems[:warp_core]
    assert_instance_of BreakerMachines::Circuit, starship_systems[:shields]
    assert_instance_of BreakerMachines::Circuit, starship_systems[:weapons]

    # Check names include group prefix
    assert_equal 'enterprise.warp_core', starship_systems[:warp_core].name
    assert_equal 'enterprise.shields', starship_systems[:shields].name
  end

  def test_circuit_group_with_dependencies
    power_systems = BreakerMachines::CircuitGroup.new('power_grid')

    # Main power must be online for others to work
    power_systems.circuit :main_power do
      threshold failures: 1
    end

    power_systems.circuit :auxiliary_power, depends_on: :main_power do
      threshold failures: 2
    end

    power_systems.circuit :emergency_power, depends_on: %i[main_power auxiliary_power] do
      threshold failures: 3
    end

    # Initially all should be healthy
    assert_predicate power_systems, :all_healthy?
    refute_predicate power_systems, :any_open?

    # Trip main power
    assert_raises(StandardError) do
      power_systems[:main_power].call { raise 'Power failure!' }
    end

    assert_predicate power_systems[:main_power], :open?

    # Dependent circuits should not be callable
    error = assert_raises(BreakerMachines::CircuitDependencyError) do
      power_systems[:auxiliary_power].call { 'Should not execute' }
    end
    assert_match(/Dependencies not met/, error.message)

    # Emergency power depends on both
    error = assert_raises(BreakerMachines::CircuitDependencyError) do
      power_systems[:emergency_power].call { 'Should not execute' }
    end
    assert_match(/Dependencies not met/, error.message)
  end

  def test_circuit_group_with_custom_guards
    api_group = BreakerMachines::CircuitGroup.new('api')

    # Shared state
    api_healthy = true

    api_group.circuit :health_check do
      threshold failures: 1
    end

    api_group.circuit :api_calls, guard_with: -> { api_healthy } do
      threshold failures: 5
    end

    # API calls work when healthy
    result = api_group[:api_calls].call { 'Success' }

    assert_equal 'Success', result

    # Disable via guard
    api_healthy = false
    assert_raises(BreakerMachines::CircuitDependencyError) do
      api_group[:api_calls].call { 'Should fail' }
    end
  end

  def test_circuit_group_operations
    systems = BreakerMachines::CircuitGroup.new('systems')

    systems.circuit :database
    systems.circuit :cache
    systems.circuit :queue

    # Get all statuses
    status = systems.status

    assert_equal :closed, status[:database]
    assert_equal :closed, status[:cache]
    assert_equal :closed, status[:queue]

    # Trip all circuits
    systems.trip_all!

    assert_predicate systems, :any_open?
    refute_predicate systems, :all_healthy?

    status = systems.status

    assert_equal :open, status[:database]
    assert_equal :open, status[:cache]
    assert_equal :open, status[:queue]

    # Reset all
    systems.reset_all!

    assert_predicate systems, :all_healthy?
    refute_predicate systems, :any_open?
  end

  def test_circuit_group_with_cascading
    network_stack = BreakerMachines::CircuitGroup.new('network')

    # Network layer cascades to application layer
    network_stack.circuit :network_layer, cascades_to: ['network.app_layer', 'network.session_layer'] do
      threshold failures: 1
    end

    network_stack.circuit :app_layer do
      threshold failures: 2
    end

    network_stack.circuit :session_layer do
      threshold failures: 2
    end

    # Register circuits so cascade can find them
    BreakerMachines.register(network_stack[:app_layer])
    BreakerMachines.register(network_stack[:session_layer])

    # Trip network layer
    assert_raises(StandardError) do
      network_stack[:network_layer].call { raise 'Network down!' }
    end

    # Should cascade to dependent layers
    assert_predicate network_stack[:network_layer], :open?
    assert_predicate network_stack[:app_layer], :open?
    assert_predicate network_stack[:session_layer], :open?
  end

  def test_async_circuit_group
    # Skip if async not available
    begin
      require 'async'
    rescue LoadError
      skip 'Async gem not available'
    end

    async_services = BreakerMachines::CircuitGroup.new('async_services',
                                                       async_mode: true)

    async_services.circuit :async_api do
      threshold failures: 3
      timeout 1
    end

    async_services.circuit :async_db do
      threshold failures: 2
    end

    # Should create AsyncCircuit instances
    assert_instance_of BreakerMachines::AsyncCircuit, async_services[:async_api]
    assert_instance_of BreakerMachines::AsyncCircuit, async_services[:async_db]

    # Test async functionality
    Async do
      result = async_services[:async_api].call_async { 'Async result' }.wait

      assert_equal 'Async result', result
    end
  end

  def test_complex_dependency_chain
    services = BreakerMachines::CircuitGroup.new('microservices')

    # Define a complex dependency chain
    services.circuit :database do
      threshold failures: 1
    end

    services.circuit :cache, depends_on: :database do
      threshold failures: 2
    end

    services.circuit :auth_service, depends_on: :database do
      threshold failures: 2
    end

    services.circuit :api_gateway, depends_on: %i[cache auth_service] do
      threshold failures: 3
    end

    services.circuit :web_frontend, depends_on: :api_gateway do
      threshold failures: 5
    end

    # Check dependency chain
    assert services.dependencies_met?(:database)
    assert services.dependencies_met?(:cache)
    assert services.dependencies_met?(:auth_service)
    assert services.dependencies_met?(:api_gateway)
    assert services.dependencies_met?(:web_frontend)

    # Break the database
    assert_raises(StandardError) do
      services[:database].call { raise 'DB connection lost' }
    end

    # Everything downstream should be affected
    refute services.dependencies_met?(:cache)
    refute services.dependencies_met?(:auth_service)
    refute services.dependencies_met?(:api_gateway)
    refute services.dependencies_met?(:web_frontend)

    # Only database circuit is actually open
    assert_predicate services[:database], :open?
    assert_predicate services[:cache], :closed?
    assert_predicate services[:auth_service], :closed?

    # But they can't be called due to dependencies
    assert_raises(BreakerMachines::CircuitDependencyError) do
      services[:web_frontend].call { 'Should not work' }
    end
  end
end
