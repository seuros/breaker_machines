# frozen_string_literal: true

require 'test_helper'

class RateThresholdTest < ActiveSupport::TestCase
  def setup
    BreakerMachines.reset!
  end

  def test_rate_at_exact_50_percent_boundary
    # Circuit with 50% failure rate threshold, minimum 10 calls
    circuit = BreakerMachines::Circuit.new(:rate_boundary, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 10,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # Make exactly 10 calls: 5 success, 5 failures = 50% failure rate
    5.times { circuit.wrap { 'success' } }

    5.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # 50% equals threshold, should trip
    assert_predicate circuit, :open?, 'Circuit should open at exactly 50% failure rate'
  end

  def test_rate_just_below_threshold_stays_closed
    circuit = BreakerMachines::Circuit.new(:rate_below, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 10,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # Make 10 calls: 6 success, 4 failures = 40% failure rate
    6.times { circuit.wrap { 'success' } }

    4.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # 40% is below 50% threshold
    assert_predicate circuit, :closed?, 'Circuit should stay closed below threshold'
  end

  def test_minimum_calls_enforced_before_rate_evaluation
    circuit = BreakerMachines::Circuit.new(:rate_minimum, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 20,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # Record failures below minimum_calls - circuit should stay closed
    10.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # 10 failures out of 10 = 100%, but below minimum_calls (20)
    assert_predicate circuit, :closed?, 'Circuit should stay closed below minimum_calls'

    # Add successes to reach minimum_calls (10 failures + 9 successes = 19 total)
    9.times { circuit.wrap { 'success' } }

    assert_predicate circuit, :closed?, 'Circuit should stay closed at 19 calls (below minimum)'

    # 20th call is a failure: 11 failures / 20 total = 55% (above 50% threshold)
    # This failure triggers threshold check at minimum_calls
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }

    # Now at minimum_calls with failure rate above threshold
    assert_predicate circuit, :open?, 'Circuit should open after reaching minimum_calls with high failure rate'
  end

  def test_zero_percent_threshold
    circuit = BreakerMachines::Circuit.new(:rate_zero, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.0,
                                             minimum_calls: 5,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # Any failure at 0% threshold should trip (after minimum_calls)
    5.times { circuit.wrap { 'success' } }

    # Now at minimum_calls, any failure should trip
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }
    assert_predicate circuit, :open?, 'Circuit should open at 0% threshold with any failure'
  end

  def test_100_percent_threshold_never_trips_on_rate
    circuit = BreakerMachines::Circuit.new(:rate_hundred, {
                                             use_rate_threshold: true,
                                             failure_rate: 1.0, # 100%
                                             minimum_calls: 5,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # 100% failure rate still doesn't trip at 99.99...%
    5.times { circuit.wrap { 'success' } }

    100.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # 100/105 = 95.2%, below 100% threshold
    assert_predicate circuit, :closed?, 'Circuit should stay closed below 100% threshold'
  end

  def test_rate_threshold_ignores_absolute_when_enabled
    # When use_rate_threshold: true, only rate-based logic is used
    circuit = BreakerMachines::Circuit.new(:rate_only, {
                                             failure_threshold: 2, # Would trigger if used
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 10,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # 5 failures (would exceed absolute threshold of 2)
    5.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # Circuit should stay closed - rate threshold needs minimum_calls
    assert_predicate circuit, :closed?, 'Rate mode ignores absolute threshold'

    # Add successes and one more failure to reach minimum and exceed rate
    4.times { circuit.wrap { 'success' } }
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }

    # Now: 6 failures / 10 total = 60% >= 50% threshold
    assert_predicate circuit, :open?, 'Circuit should open when rate threshold met'
  end

  def test_absolute_threshold_when_rate_disabled
    # When use_rate_threshold: false (default), only absolute count is used
    circuit = BreakerMachines::Circuit.new(:absolute_only, {
                                             failure_threshold: 3,
                                             use_rate_threshold: false,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # Trigger absolute threshold
    3.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # Should trip on absolute count
    assert_predicate circuit, :open?, 'Circuit should open on absolute threshold'
  end

  def test_rate_threshold_with_sliding_window
    circuit = BreakerMachines::Circuit.new(:rate_window, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 10,
                                             failure_window: 2, # 2 second window
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # Record 100% failures
    10.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }
    assert_predicate circuit, :open?

    # Reset and wait for window to expire
    circuit.reset

    # Wait for failure_window to expire
    sleep 2.2

    # Old failures should be outside window, new calls start fresh
    # Record 0% failures (all success)
    10.times { circuit.wrap { 'success' } }

    assert_predicate circuit, :closed?, 'Circuit should be closed when old failures expire from window'
  end

  def test_rate_threshold_minimum_calls_exactly_met
    circuit = BreakerMachines::Circuit.new(:rate_exact_minimum, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 10,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # Make exactly minimum_calls - 1
    5.times { circuit.wrap { 'success' } }

    4.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # 9 calls total, below minimum
    assert_predicate circuit, :closed?, 'Circuit should stay closed at minimum_calls - 1'

    # 10th call (failure) - now at minimum_calls with 50% failure rate
    # 5 failures / 10 total = 50%, exactly at threshold
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }

    assert_predicate circuit, :open?, 'Circuit should open at exactly minimum_calls with threshold rate'
  end

  def test_rate_threshold_with_success_recovery
    circuit = BreakerMachines::Circuit.new(:rate_recovery, {
                                             use_rate_threshold: true,
                                             failure_rate: 0.5,
                                             minimum_calls: 10,
                                             failure_window: 60,
                                             reset_timeout: 0.5,
                                             reset_timeout_jitter: 0
                                           })

    # Build up failure rate
    5.times { circuit.wrap { 'success' } }

    5.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }

    # Circuit opens at 50%
    assert_predicate circuit, :open?

    # Wait for half-open
    sleep 0.6

    # Successful call in half-open closes circuit
    circuit.wrap { 'success' }

    assert_predicate circuit, :closed?, 'Circuit should close after successful half-open call'
  end

  def test_rate_disabled_uses_only_absolute
    circuit = BreakerMachines::Circuit.new(:no_rate, {
                                             failure_threshold: 3,
                                             use_rate_threshold: false, # Explicitly disabled
                                             failure_rate: 0.0, # Should be ignored
                                             minimum_calls: 0,
                                             failure_window: 60,
                                             reset_timeout: 1,
                                             reset_timeout_jitter: 0
                                           })

    # 2 failures shouldn't trip (below absolute threshold)
    2.times { assert_raises(RuntimeError) { circuit.wrap { raise 'error' } } }
    assert_predicate circuit, :closed?

    # 3rd failure trips
    assert_raises(RuntimeError) { circuit.wrap { raise 'error' } }
    assert_predicate circuit, :open?, 'Circuit should open on absolute threshold when rate is disabled'
  end
end
