# frozen_string_literal: true

require 'test_helper'

class ResetTest < ActiveSupport::TestCase
  class TestModule
    include BreakerMachines::DSL

    circuit :api_call do
      threshold failures: 2, within: 10
      half_open_requests 3 # Need multiple requests to close from half-open
    end

    def make_api_call(&)
      circuit(:api_call).call(&)
    end
  end

  def test_reset_all_circuits_clears_failure_counts
    instance = TestModule.new

    # Trigger failures to open circuit
    2.times do
      assert_raises(RuntimeError) do
        instance.make_api_call { raise 'API error' }
      end
    end

    # Circuit should be open
    assert_raises(BreakerMachines::CircuitOpenError) do
      instance.make_api_call { 'success' }
    end

    # Reset all circuits
    instance.reset_all_circuits

    # Circuit should be closed and failure count cleared
    circuit = instance.circuit(:api_call)

    assert_predicate circuit, :closed?
    assert_equal 0, circuit.stats.failure_count

    # Should be able to trigger one failure without opening
    assert_raises(RuntimeError) do
      instance.make_api_call { raise 'API error' }
    end

    # Circuit should still be closed (only 1 failure, threshold is 2)
    assert_predicate circuit, :closed?

    # Second failure should open it
    assert_raises(RuntimeError) do
      instance.make_api_call { raise 'API error' }
    end

    # Now circuit should be open
    assert_predicate circuit, :open?
  end

  def test_class_level_reset_affects_all_instances
    instance1 = TestModule.new
    instance2 = TestModule.new

    # Open circuits on both instances
    [instance1, instance2].each do |instance|
      2.times do
        assert_raises(RuntimeError) do
          instance.make_api_call { raise 'Error' }
        end
      end
    end

    # Both should be open
    assert_predicate instance1.circuit(:api_call), :open?
    assert_predicate instance2.circuit(:api_call), :open?

    # Class-level reset
    TestModule.reset_all_circuits

    # Both should be closed with cleared counts
    assert_predicate instance1.circuit(:api_call), :closed?
    assert_predicate instance2.circuit(:api_call), :closed?
    assert_equal 0, instance1.circuit(:api_call).stats.failure_count
    assert_equal 0, instance2.circuit(:api_call).stats.failure_count
  end

  def test_hard_reset_clears_half_open_counters
    instance = TestModule.new

    # Open the circuit
    2.times do
      assert_raises(RuntimeError) do
        instance.make_api_call { raise 'Error' }
      end
    end

    # Force to half-open to test counter reset
    circuit = instance.circuit(:api_call)
    circuit.attempt_recovery!

    # The counters might be incremented during half-open operation
    # but the key test is that hard_reset! clears them

    # Hard reset should clear these counters
    circuit.hard_reset!

    assert_equal 0, circuit.half_open_attempts.value
    assert_equal 0, circuit.half_open_successes.value
    assert_predicate circuit, :closed?
  end

  def test_hard_reset_vs_force_close_behavior
    instance = TestModule.new

    # Trigger one failure
    assert_raises(RuntimeError) do
      instance.make_api_call { raise 'Error' }
    end

    circuit = instance.circuit(:api_call)

    assert_equal 1, circuit.stats.failure_count

    # force_close! should not clear failure count
    circuit.force_close!

    assert_equal 1, circuit.stats.failure_count

    # Trigger one more failure should open it (total 2)
    assert_raises(RuntimeError) do
      instance.make_api_call { raise 'Error' }
    end
    assert_predicate circuit, :open?

    # hard_reset! should clear failure count
    circuit.hard_reset!

    assert_equal 0, circuit.stats.failure_count
    assert_predicate circuit, :closed?

    # Should be able to trigger one failure without opening again
    assert_raises(RuntimeError) do
      instance.make_api_call { raise 'Error' }
    end
    assert_predicate circuit, :closed? # Still closed because count was reset
  end

  def test_hard_reset_clears_storage_completely
    instance = TestModule.new

    # Generate some history
    instance.make_api_call { 'success' } # 1 success
    assert_raises(RuntimeError) { instance.make_api_call { raise 'Error' } } # 1 failure

    circuit = instance.circuit(:api_call)
    stats = circuit.stats

    assert_equal 1, stats.success_count
    assert_equal 1, stats.failure_count

    # Hard reset should clear all storage
    circuit.hard_reset!

    stats = circuit.stats

    assert_equal 0, stats.success_count
    assert_equal 0, stats.failure_count
    assert_predicate circuit, :closed?
  end
end
