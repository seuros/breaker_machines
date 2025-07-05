# frozen_string_literal: true

require 'test_helper'

class TestCircuit < ActiveSupport::TestCase
  class MockService
    def self.call
      'success'
    end
  end

  def setup
    @circuit = BreakerMachines::Circuit.new(:test_circuit, {
                                              failure_threshold: 3,
                                              failure_window: 60,
                                              reset_timeout: 1,
                                              reset_timeout_jitter: 0, # Disable jitter for predictable tests
                                              timeout: 2
                                            })
  end

  def test_initial_state_is_closed
    assert_predicate @circuit, :closed?
    refute_predicate @circuit, :open?
    refute_predicate @circuit, :half_open?
  end

  def test_successful_calls_keep_circuit_closed
    10.times do
      result = @circuit.wrap { MockService.call }

      assert_equal 'success', result
    end

    assert_predicate @circuit, :closed?
  end

  def test_circuit_opens_after_failure_threshold
    # Simulate failures
    3.times do
      assert_raises(RuntimeError) do
        @circuit.wrap { raise 'Service error' }
      end
    end

    # Circuit should now be open
    assert_predicate @circuit, :open?
    refute_predicate @circuit, :closed?
  end

  def test_open_circuit_rejects_calls_immediately
    # Open the circuit
    3.times do
      assert_raises(RuntimeError) do
        @circuit.wrap { raise 'Service error' }
      end
    end

    # Next call should fail immediately with CircuitOpenError
    error = assert_raises(BreakerMachines::CircuitOpenError) do
      @circuit.wrap { MockService.call }
    end

    assert_equal "Circuit 'test_circuit' is open", error.message
    assert_equal :test_circuit, error.circuit_name
  end

  def test_circuit_transitions_to_half_open_after_reset_timeout
    # Open the circuit
    3.times do
      assert_raises(RuntimeError) do
        @circuit.wrap { raise 'Service error' }
      end
    end

    assert_predicate @circuit, :open?

    # Wait for reset timeout
    sleep 1.1

    # Next call should be allowed (half-open state)
    result = @circuit.wrap { MockService.call }

    assert_equal 'success', result

    # Circuit should be closed again
    assert_predicate @circuit, :closed?
  end

  def test_half_open_circuit_reopens_on_failure
    # Open the circuit
    3.times do
      assert_raises(RuntimeError) do
        @circuit.wrap { raise 'Service error' }
      end
    end

    # Wait for reset timeout
    sleep 1.1

    # Fail in half-open state
    assert_raises(RuntimeError) do
      @circuit.wrap { raise 'Still failing' }
    end

    # Circuit should be open again
    assert_predicate @circuit, :open?
  end

  def test_timeout_configuration_is_documented_only
    # Timeout configuration is for documentation purposes only
    # Actual timeouts must be implemented by the caller
    slow_circuit = BreakerMachines::Circuit.new(:slow_circuit, {
                                                  failure_threshold: 2,
                                                  timeout: 0.1
                                                })

    # The circuit executes normally without forceful timeout
    result = slow_circuit.wrap do
      # In real usage, you would use library-specific timeouts
      # e.g., Faraday's request.options.timeout
      'completed'
    end

    assert_equal 'completed', result
    assert_predicate slow_circuit, :closed?
  end

  def test_fallback_is_invoked_when_configured
    circuit_with_fallback = BreakerMachines::Circuit.new(:with_fallback, {
                                                           failure_threshold: 1,
                                                           fallback: ->(_error) { 'fallback result' }
                                                         })

    # Trigger failure
    result = circuit_with_fallback.wrap { raise 'Service error' }

    assert_equal 'fallback result', result

    # Circuit should be open
    assert_predicate circuit_with_fallback, :open?

    # Fallback should work for open circuit too
    result = circuit_with_fallback.wrap { 'should not execute' }

    assert_equal 'fallback result', result
  end

  def test_callbacks_are_invoked
    events = []

    circuit_with_callbacks = BreakerMachines::Circuit.new(:with_callbacks, {
                                                            failure_threshold: 2,
                                                            reset_timeout: 0.5,
                                                            reset_timeout_jitter: 0, # Disable jitter for test
                                                            on_open: -> { events << :opened },
                                                            on_close: -> { events << :closed },
                                                            on_half_open: -> { events << :half_opened },
                                                            on_reject: -> { events << :rejected }
                                                          })

    # Trigger failures to open circuit
    2.times do
      assert_raises(RuntimeError) do
        circuit_with_callbacks.wrap { raise 'error' }
      end
    end

    assert_includes events, :opened

    # Try to call while open (should be rejected)
    assert_raises(BreakerMachines::CircuitOpenError) do
      circuit_with_callbacks.wrap { 'test' }
    end

    assert_includes events, :rejected

    # Wait for half-open
    sleep 0.6

    # Successful call should close circuit
    circuit_with_callbacks.wrap { 'success' }

    assert_includes events, :closed
  end

  def test_thread_safety
    results = []
    errors = []
    threads = []

    circuit = BreakerMachines::Circuit.new(:concurrent_circuit, {
                                             failure_threshold: 5,
                                             failure_window: 60
                                           })

    # Launch multiple threads
    10.times do |i|
      threads << Thread.new do
        result = circuit.wrap do
          raise "Error #{i}" if i < 5

          "Success #{i}"
        end
        results << result
      rescue StandardError => e
        errors << e
      end
    end

    threads.each(&:join)

    # Should have some failures (at least the RuntimeErrors)
    assert(errors.any? { |e| e.is_a?(RuntimeError) || e.is_a?(BreakerMachines::CircuitOpenError) })
    # Circuit behavior was thread-safe (no crashes, all threads completed)
    assert_equal 10, results.size + errors.size
  end
end
