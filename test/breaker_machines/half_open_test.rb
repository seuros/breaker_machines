# frozen_string_literal: true

require 'test_helper'

class HalfOpenTest < ActiveSupport::TestCase
  def setup
    BreakerMachines.reset!
  end

  def test_single_failure_in_half_open_reopens_circuit
    circuit = BreakerMachines::Circuit.new(:half_open_reopen, {
                                             failure_threshold: 2,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             success_threshold: 3
                                           })

    # Open the circuit
    2.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }
    assert_predicate circuit, :open?

    # Wait for half-open
    sleep 0.6

    # Single failure should immediately reopen
    assert_raises(RuntimeError) { circuit.wrap { raise 'still failing' } }

    assert_predicate circuit, :open?, 'Circuit should reopen after half-open failure'
  end

  def test_success_threshold_required_to_close
    circuit = BreakerMachines::Circuit.new(:half_open_threshold, {
                                             failure_threshold: 2,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             success_threshold: 3,
                                             half_open_calls: 5 # Allow enough calls for success_threshold
                                           })

    # Open and transition to half-open
    2.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }
    sleep 0.6

    # First success - still half-open
    circuit.wrap { 'success 1' }

    assert_predicate circuit, :half_open?, 'Should still be half-open after 1 success'

    # Second success - still half-open
    circuit.wrap { 'success 2' }

    assert_predicate circuit, :half_open?, 'Should still be half-open after 2 successes'

    # Third success - should close
    circuit.wrap { 'success 3' }

    assert_predicate circuit, :closed?, 'Should close after success_threshold successes'
  end

  def test_failure_in_half_open_reopens_circuit
    circuit = BreakerMachines::Circuit.new(:half_open_failure, {
                                             failure_threshold: 2,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             success_threshold: 3,
                                             half_open_calls: 5
                                           })

    # Open the circuit
    2.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }
    assert_predicate circuit, :open?

    # Wait for half-open
    sleep 0.6

    # Record some successes (but not enough to close)
    2.times { circuit.wrap { 'success' } }

    assert_predicate circuit, :half_open?, 'Should still be half-open after 2 successes (need 3)'

    # Failure in half-open should reopen the circuit
    assert_raises(RuntimeError) { circuit.wrap { raise 'failure in half-open' } }

    # Circuit should be open again
    assert_predicate circuit, :open?, 'Circuit should reopen after failure in half-open state'
  end

  def test_half_open_callbacks_triggered
    events = []

    circuit = BreakerMachines::Circuit.new(:half_open_callbacks, {
                                             failure_threshold: 1,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             on_open: -> { events << :opened },
                                             on_half_open: -> { events << :half_opened },
                                             on_close: -> { events << :closed }
                                           })

    # Trigger open
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }
    assert_includes events, :opened

    # Wait for half-open
    sleep 0.6

    # Trigger half-open callback on next call attempt
    circuit.wrap { 'probe' }

    assert_includes events, :half_opened
    assert_includes events, :closed
  end

  def test_half_open_with_rate_threshold
    circuit = BreakerMachines::Circuit.new(:half_open_rate, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 10,
                                             failure_window: 60,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             success_threshold: 2
                                           })

    # Build up to threshold
    5.times { circuit.wrap { 'success' } }

    5.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    assert_predicate circuit, :open?

    # Wait for half-open
    sleep 0.6

    # Successes in half-open should close
    2.times { circuit.wrap { 'success' } }

    assert_predicate circuit, :closed?
  end

  def test_half_open_request_limit
    # Some implementations limit requests in half-open state
    # This documents the current behavior
    circuit = BreakerMachines::Circuit.new(:half_open_limit, {
                                             failure_threshold: 1,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             half_open_calls: 2, # Only allow 2 probe requests
                                             success_threshold: 2
                                           })

    # Open the circuit
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }

    # Wait for half-open
    sleep 0.6

    # First call allowed
    result1 = circuit.wrap { 'probe 1' }

    assert_equal 'probe 1', result1

    # Second call allowed (and should close circuit with success_threshold: 2)
    result2 = circuit.wrap { 'probe 2' }

    assert_equal 'probe 2', result2

    # Circuit should now be closed
    assert_predicate circuit, :closed?
  end

  def test_concurrent_half_open_probes
    circuit = BreakerMachines::Circuit.new(:half_open_concurrent, {
                                             failure_threshold: 1,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             success_threshold: 1
                                           })

    # Open the circuit
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }

    # Wait for half-open
    sleep 0.6

    results = Concurrent::Array.new
    errors = Concurrent::Array.new

    # Launch concurrent probes
    threads = 10.times.map do
      Thread.new do
        result = circuit.wrap { 'success' }
        results << result
      rescue BreakerMachines::CircuitOpenError => e
        errors << e
      end
    end

    threads.each(&:join)

    # At least one probe should succeed (first one closes circuit)
    # Others may succeed or get CircuitOpenError depending on timing
    assert results.any? || errors.any?, 'Should have some results'
    assert_predicate circuit, :closed?, 'Circuit should eventually close'
  end

  def test_half_open_timeout_resets_on_reopen
    circuit = BreakerMachines::Circuit.new(:half_open_timeout_reset, {
                                             failure_threshold: 1,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0
                                           })

    # First cycle: open -> half-open -> reopen
    assert_raises(RuntimeError) { circuit.wrap { raise 'error 1' } }
    sleep 0.6
    assert_raises(RuntimeError) { circuit.wrap { raise 'error in half-open' } }

    # Should be open again with fresh timeout
    assert_predicate circuit, :open?

    # Immediate attempt should fail (timeout not elapsed)
    assert_raises(BreakerMachines::CircuitOpenError) { circuit.wrap { 'too soon' } }

    # Wait for new timeout
    sleep 0.6

    # Should be half-open again
    circuit.wrap { 'success' }

    assert_predicate circuit, :closed?
  end

  def test_half_open_preserves_statistics
    circuit = BreakerMachines::Circuit.new(:half_open_stats, {
                                             failure_threshold: 2,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0,
                                             failure_window: 60
                                           })

    # Record some successes first
    5.times { circuit.wrap { 'success' } }

    # Open the circuit
    2.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    initial_success_count = circuit.stats.success_count

    # Wait for half-open and succeed
    sleep 0.6
    circuit.wrap { 'recovery' }

    final_success_count = circuit.stats.success_count

    # Stats should be preserved/updated through the transition
    assert_operator final_success_count, :>, initial_success_count, 'Success count should increase'
  end
end
