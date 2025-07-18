# frozen_string_literal: true

require 'test_helper'

class CoordinatedCircuitTest < Minitest::Test
  def setup
    BreakerMachines.reset!
    BreakerMachines.config.default_storage = :memory
  end

  def test_cascading_circuit_with_coordinated_recovery
    # Create main system circuit
    main_power = BreakerMachines::Circuit.new('main_power', {
                                                failure_threshold: 1,
                                                reset_timeout: 0.1
                                              })

    # Create dependent circuit that cascades when main_power fails
    weapons = BreakerMachines::CascadingCircuit.new('weapons', {
                                                      failure_threshold: 1,
                                                      reset_timeout: 0.1,
                                                      cascades_to: %w[shields targeting]
                                                    })

    shields = BreakerMachines::Circuit.new('shields', {
                                             failure_threshold: 2,
                                             reset_timeout: 0.1
                                           })

    targeting = BreakerMachines::Circuit.new('targeting', {
                                               failure_threshold: 2,
                                               reset_timeout: 0.1
                                             })

    # Register all circuits
    BreakerMachines.register(main_power)
    BreakerMachines.register(weapons)
    BreakerMachines.register(shields)
    BreakerMachines.register(targeting)

    # Verify initial states
    assert_equal :closed, weapons.status_name
    assert_equal :closed, shields.status_name
    assert_equal :closed, targeting.status_name

    # Trip the weapons circuit - should cascade to shields and targeting
    assert_raises(StandardError) do
      weapons.call { raise 'Weapons system failure!' }
    end

    # All dependent circuits should be open
    assert_equal :open, weapons.status_name
    assert_equal :open, shields.status_name
    assert_equal :open, targeting.status_name

    # Wait for reset timeout
    sleep 0.15

    # Weapons should not be able to recover while dependencies are still down
    refute_predicate weapons, :recovery_allowed?

    # Manually close the dependent circuits
    shields.force_close!
    targeting.force_close!

    # Now weapons should be able to attempt recovery
    assert_predicate weapons, :recovery_allowed?

    # Attempt recovery should succeed
    weapons.attempt_recovery!

    assert_equal :half_open, weapons.status_name

    # Successful call should reset the circuit
    result = weapons.call { 'Success!' }

    assert_equal 'Success!', result
    assert_equal :closed, weapons.status_name
  end

  def test_coordinated_circuit_prevents_reset_with_dependencies_down
    # Create interdependent circuits
    network = BreakerMachines::CascadingCircuit.new('network', {
                                                      failure_threshold: 1,
                                                      cascades_to: %w[database cache]
                                                    })

    database = BreakerMachines::Circuit.new('database', {
                                              failure_threshold: 1
                                            })

    cache = BreakerMachines::Circuit.new('cache', {
                                           failure_threshold: 1
                                         })

    BreakerMachines.register(network)
    BreakerMachines.register(database)
    BreakerMachines.register(cache)

    # Trip the network circuit
    assert_raises(StandardError) do
      network.call { raise 'Network failure!' }
    end

    # All should be open
    assert_equal :open, network.status_name
    assert_equal :open, database.status_name
    assert_equal :open, cache.status_name

    # Network should not be able to reset while dependencies are down
    refute_predicate network, :reset_allowed?

    # Closing one dependency is not enough
    database.force_close!

    refute_predicate network, :reset_allowed?

    # All dependencies must be healthy
    cache.force_close!

    assert_predicate network, :reset_allowed?

    # Now reset should work
    network.reset!

    assert_equal :closed, network.status_name
  end

  def test_cascading_circuit_with_mixed_dependency_states
    parent = BreakerMachines::CascadingCircuit.new('parent', {
                                                     failure_threshold: 1,
                                                     cascades_to: %w[child1 child2 child3]
                                                   })

    child1 = BreakerMachines::Circuit.new('child1', failure_threshold: 1)
    child2 = BreakerMachines::Circuit.new('child2', failure_threshold: 1)
    child3 = BreakerMachines::Circuit.new('child3', failure_threshold: 1)

    BreakerMachines.register(parent)
    BreakerMachines.register(child1)
    BreakerMachines.register(child2)
    BreakerMachines.register(child3)

    # Trip parent to cascade failure
    assert_raises(StandardError) do
      parent.call { raise 'Parent failure!' }
    end

    # All should be open
    assert_predicate parent, :open?
    assert_predicate child1, :open?
    assert_predicate child2, :open?
    assert_predicate child3, :open?

    # Put children in different states
    child1.force_close! # closed
    child2.attempt_recovery! if child2.respond_to?(:attempt_recovery!) # half_open
    # child3 remains open

    # Parent should not reset - not all dependencies are healthy
    refute_predicate parent, :reset_allowed?
  end
end
