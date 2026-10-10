# frozen_string_literal: true

require 'test_helper'

class CircuitNativeTest < Minitest::Test
  def setup
    @circuit_name = "test_native_circuit_#{SecureRandom.hex(4)}"
  end

  def skip_if_native_unavailable
    skip 'Native extension not available' unless BreakerMachines.native_available?
  end

  def test_circuit_creation
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(
      @circuit_name,
      failure_threshold: 3,
      failure_window_secs: 60.0
    )

    assert_equal @circuit_name, circuit.name
    assert_predicate circuit, :closed?
    refute_predicate circuit, :open?
    assert_equal 'closed', circuit.state
  end

  def test_circuit_opens_after_failures
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(
      @circuit_name,
      failure_threshold: 3,
      failure_window_secs: 60.0
    )

    # Circuit should be closed initially
    assert_predicate circuit, :closed?

    # Record failures
    3.times do
      assert_raises(StandardError) do
        circuit.call { raise StandardError, 'test error' }
      end
    end

    # Circuit should be open now
    assert_predicate circuit, :open?
    assert_equal 'open', circuit.state
  end

  def test_circuit_raises_when_open
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(
      @circuit_name,
      failure_threshold: 2,
      failure_window_secs: 60.0
    )

    # Open the circuit
    2.times do
      assert_raises(StandardError) do
        circuit.call { raise StandardError, 'test error' }
      end
    end

    # Should raise CircuitOpenError
    error = assert_raises(BreakerMachines::CircuitOpenError) do
      circuit.call { 'should not execute' }
    end

    assert_match(/Circuit.*is open/, error.message)
  end

  def test_circuit_records_successes
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(
      @circuit_name,
      failure_threshold: 5,
      failure_window_secs: 60.0
    )

    result = circuit.call { 'success' }

    assert_equal 'success', result
    assert_predicate circuit, :closed?
  end

  def test_circuit_reset
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(
      @circuit_name,
      failure_threshold: 2,
      failure_window_secs: 60.0
    )

    # Open the circuit
    2.times do
      assert_raises(StandardError) do
        circuit.call { raise StandardError, 'test error' }
      end
    end

    assert_predicate circuit, :open?

    # Reset should close it
    circuit.reset!

    assert_predicate circuit, :closed?
  end

  def test_circuit_status
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(
      @circuit_name,
      failure_threshold: 3,
      failure_window_secs: 60.0
    )

    status = circuit.status

    assert_equal @circuit_name, status[:name]
    assert_equal 'closed', status[:state]
    assert status[:closed]
    refute status[:open]
    assert_kind_of Hash, status[:config]
  end

  def test_native_unavailable_raises_error
    skip_if_native_unavailable

    # Temporarily pretend native is unavailable
    original = BreakerMachines.instance_variable_get(:@native_available)
    BreakerMachines.instance_variable_set(:@native_available, false)

    error = assert_raises(BreakerMachines::ConfigurationError) do
      BreakerMachines::Circuit::Native.new(@circuit_name)
    end

    assert_match(/Native extension not available/, error.message)
  ensure
    BreakerMachines.instance_variable_set(:@native_available, original)
  end

  # Raised by test blocks; not a StandardError, so it must not count.
  class Boom < Exception; end # rubocop:disable Lint/InheritException

  HALF_OPEN_TIMEOUT = 0.05

  def test_recovers_through_half_open_after_the_cooldown
    skip_if_native_unavailable
    circuit = tripped_circuit(success_threshold: 2)
    wait_for_cooldown

    assert_equal(:probe, circuit.call { :probe })
    assert_predicate circuit, :half_open?
    assert_equal 'half_open', circuit.state

    assert_equal(:probe, circuit.call { :probe })
    assert_predicate circuit, :closed?
  end

  def test_half_open_failure_reopens
    skip_if_native_unavailable
    circuit = tripped_circuit(success_threshold: 2)
    wait_for_cooldown

    still_down = RuntimeError.new('still down')
    raised = assert_raises(RuntimeError) { circuit.call { raise still_down } }

    assert_same still_down, raised, 'the block error is re-raised unchanged'
    assert_predicate circuit, :open?
    assert_raises(BreakerMachines::CircuitOpenError) { circuit.call { :rejected } }
  end

  def test_open_error_carries_circuit_name_and_opened_at
    skip_if_native_unavailable
    circuit = tripped_circuit
    tripped_at = BreakerMachines.monotonic_time

    error = assert_raises(BreakerMachines::CircuitOpenError) { circuit.call { :rejected } }

    assert_equal @circuit_name, error.circuit_name
    assert_in_delta tripped_at, error.opened_at, 0.5
  end

  def test_block_can_reenter_the_circuit
    skip_if_native_unavailable
    circuit = tripped_circuit(success_threshold: 2)
    wait_for_cooldown

    # No borrow is held while the block runs, so it may read or call the circuit.
    seen = circuit.call { [circuit.state, circuit.open?, circuit.call { :nested }] }

    assert_equal ['half_open', false, :nested], seen
  end

  def test_non_standard_errors_and_throw_do_not_count
    skip_if_native_unavailable
    circuit = tripped_circuit(success_threshold: 1)
    wait_for_cooldown

    assert_raises(Boom) { circuit.call { raise Boom } }
    assert_equal :thrown, catch(:done) { circuit.call { throw :done, :thrown } }

    # Both probes were abandoned: not counted, and their slot is free again.
    assert_predicate circuit, :half_open?
    assert_equal(:ok, circuit.call { :ok })
    assert_predicate circuit, :closed?
  end

  def test_break_leaves_the_block_without_counting
    skip_if_native_unavailable
    circuit = tripped_circuit(success_threshold: 1)
    wait_for_cooldown

    assert_equal(:broke, circuit.call { break :broke })

    assert_predicate circuit, :half_open?
    assert_equal(:ok, circuit.call { :ok })
    assert_predicate circuit, :closed?
  end

  def test_native_call_requires_a_block
    skip_if_native_unavailable
    native = BreakerMachinesNative::Circuit.new(@circuit_name, { failure_threshold: 1 })

    assert_raises(LocalJumpError) { native.call }
    assert_equal(:ok, native.call { :ok })
    assert native.is_closed, 'a missing block must not count as a failure'
  end

  def test_config_defaults
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(@circuit_name)

    assert_equal 5, circuit.config[:failure_threshold]
    assert_in_delta(60.0, circuit.config[:failure_window_secs])
    assert_in_delta(30.0, circuit.config[:half_open_timeout_secs])
    assert_equal 2, circuit.config[:success_threshold]
  end

  private

  def tripped_circuit(success_threshold: 2)
    circuit = BreakerMachines::Circuit::Native.new(
      @circuit_name,
      failure_threshold: 1,
      half_open_timeout_secs: HALF_OPEN_TIMEOUT,
      success_threshold: success_threshold,
      auto_register: false
    )
    assert_raises(RuntimeError) { circuit.call { raise 'down' } }
    assert_predicate circuit, :open?
    circuit
  end

  def wait_for_cooldown
    # Twice the cooldown: `sleep` waits at least that long, so it has elapsed.
    sleep(HALF_OPEN_TIMEOUT * 2)
  end
end
