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

  def test_config_defaults
    skip_if_native_unavailable

    circuit = BreakerMachines::Circuit::Native.new(@circuit_name)

    assert_equal 5, circuit.config[:failure_threshold]
    assert_in_delta(60.0, circuit.config[:failure_window_secs])
    assert_in_delta(30.0, circuit.config[:half_open_timeout_secs])
    assert_equal 2, circuit.config[:success_threshold]
  end
end
