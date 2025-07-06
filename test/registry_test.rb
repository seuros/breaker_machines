# frozen_string_literal: true

require 'test_helper'

class TestRegistry < ActiveSupport::TestCase
  def setup
    @registry = BreakerMachines::Registry.instance
    @registry.clear
  end

  def teardown
    @registry.clear
  end

  def test_find_returns_first_circuit_by_name
    circuit1 = BreakerMachines::Circuit.new(:test_api, {})
    _circuit2 = BreakerMachines::Circuit.new(:test_api, {})
    circuit3 = BreakerMachines::Circuit.new(:other_api, {})

    found = @registry.find(:test_api)

    assert_equal circuit1, found

    found_other = @registry.find(:other_api)

    assert_equal circuit3, found_other

    not_found = @registry.find(:nonexistent)

    assert_nil not_found
  end

  def test_force_open_circuits_by_name
    circuit1 = BreakerMachines::Circuit.new(:test_api, {})
    circuit2 = BreakerMachines::Circuit.new(:test_api, {})

    assert_predicate circuit1, :closed?
    assert_predicate circuit2, :closed?

    result = @registry.force_open(:test_api)

    assert result

    assert_predicate circuit1, :open?
    assert_predicate circuit2, :open?

    # Returns false for nonexistent circuits
    result = @registry.force_open(:nonexistent)

    refute result
  end

  def test_force_close_circuits_by_name
    circuit1 = BreakerMachines::Circuit.new(:test_api, {})
    circuit2 = BreakerMachines::Circuit.new(:test_api, {})

    # Open them first
    circuit1.force_open
    circuit2.force_open

    assert_predicate circuit1, :open?
    assert_predicate circuit2, :open?

    result = @registry.force_close(:test_api)

    assert result

    assert_predicate circuit1, :closed?
    assert_predicate circuit2, :closed?
  end

  def test_reset_circuits_by_name
    circuit = BreakerMachines::Circuit.new(:test_api, {
                                             failure_threshold: 1,
                                             reset_timeout: 100
                                           })

    # Trip the circuit
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }
    assert_predicate circuit, :open?

    result = @registry.reset(:test_api)

    assert result

    assert_predicate circuit, :closed?
  end

  def test_all_stats_returns_comprehensive_metrics
    circuit1 = BreakerMachines::Circuit.new(:api_one, {})
    circuit2 = BreakerMachines::Circuit.new(:api_two, {})

    # Generate some activity
    circuit1.wrap { 'success' }
    circuit2.wrap { 'success' }
    assert_raises(RuntimeError) { circuit2.wrap { raise 'error' } }

    stats = @registry.all_stats

    assert_equal 2, stats[:summary][:total]
    assert_equal 2, stats[:summary][:by_state][:closed]

    assert_equal 2, stats[:circuits].size
    assert(stats[:circuits].all? { |c| c.is_a?(Hash) })

    assert_equal 0, stats[:health][:open_count]
    assert_equal 2, stats[:health][:closed_count]
    assert_equal 0, stats[:health][:half_open_count]
    assert_operator stats[:health][:total_successes], :>=, 2
    assert_operator stats[:health][:total_failures], :>=, 1
  end

  def test_registry_handles_garbage_collected_circuits
    # Create circuit and ensure it can be GC'd
    initial_count = @registry.all_circuits.size

    # Create temporary circuit
    BreakerMachines::Circuit.new(:temp_circuit, {})

    assert_equal initial_count + 1, @registry.all_circuits.size

    # Force cleanup of dead references
    @registry.cleanup_dead_references

    # Should still have the circuit since it's likely still alive
    # This test mainly verifies cleanup_dead_references doesn't crash
    assert_operator @registry.all_circuits.size, :>=, initial_count
  end
end
