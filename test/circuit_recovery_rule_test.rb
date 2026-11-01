# frozen_string_literal: true

require 'test_helper'

# Recovery is one control law, so every backend must answer it the same way:
# +success_threshold+ successful probes close a half-open circuit, and a failed
# probe reopens it. The native circuit takes part whenever the extension is
# loaded, so `BREAKER_MACHINES_NATIVE=1` compares the two implementations.
class CircuitRecoveryRuleTest < ActiveSupport::TestCase
  COOLDOWN = 0.05
  SUCCESS_THRESHOLD = 3
  FAILURE_WINDOW = 60

  def setup
    BreakerMachines.reset!
  end

  def test_probes_close_the_circuit_at_the_success_threshold
    each_backend do |klass|
      circuit = tripped_circuit(klass, failure_threshold: 1, success_threshold: SUCCESS_THRESHOLD)

      trace = Array.new(SUCCESS_THRESHOLD) do
        circuit.call { :ok }
        [circuit.status_name, circuit.stats.half_open_successes]
      end

      assert_equal [[:half_open, 1], [:half_open, 2], [:closed, 0]], trace, klass.name
    end
  end

  def test_a_failed_probe_reopens_the_circuit_below_the_failure_threshold
    each_backend do |klass|
      # Opened without recording failures, so the window holds fewer than
      # +failure_threshold+ of them while the probe runs.
      circuit = forced_open_circuit(klass, failure_threshold: 2, success_threshold: SUCCESS_THRESHOLD)

      circuit.call { :ok }

      assert_equal [:half_open, 1], [circuit.status_name, circuit.stats.half_open_successes], klass.name

      assert_raises(RuntimeError) { circuit.call { raise 'still down' } }
      assert_equal [:open, 0], [circuit.status_name, circuit.stats.half_open_successes], klass.name
      assert_raises(BreakerMachines::CircuitOpenError, klass.name) do
        circuit.call { flunk "#{klass.name} admitted a call after a failed probe" }
      end
    end
  end

  def test_half_open_calls_caps_the_probes_in_flight
    each_backend do |klass|
      circuit = tripped_circuit(klass, failure_threshold: 1, success_threshold: SUCCESS_THRESHOLD,
                                       half_open_calls: 1)

      nested = circuit.call do
        begin
          circuit.call { :admitted }
        rescue BreakerMachines::CircuitOpenError
          :refused
        end
      end

      assert_equal :refused, nested, klass.name
    end
  end

  def test_half_open_calls_admits_up_to_its_limit
    each_backend do |klass|
      circuit = tripped_circuit(klass, failure_threshold: 1, success_threshold: SUCCESS_THRESHOLD,
                                       half_open_calls: 2)

      nested = circuit.call do
        begin
          circuit.call { :admitted }
        rescue BreakerMachines::CircuitOpenError
          :refused
        end
      end

      assert_equal :admitted, nested, klass.name
    end
  end

  private

  def each_backend(&)
    backends = [BreakerMachines::Circuit]
    backends << BreakerMachines::Circuit::Native if BreakerMachines.native_available?
    backends.each(&)
  end

  def tripped_circuit(klass, failure_threshold:, **options)
    circuit = build_circuit(klass, failure_threshold: failure_threshold, **options)
    failure_threshold.times { assert_raises(RuntimeError) { circuit.call { raise 'down' } } }
    assert_predicate circuit, :open?
    wait_for_cooldown
    circuit
  end

  def forced_open_circuit(klass, **options)
    circuit = build_circuit(klass, **options)
    circuit.force_open
    assert_predicate circuit, :open?
    wait_for_cooldown
    circuit
  end

  def build_circuit(klass, **options)
    options.merge!(
      if klass == BreakerMachines::Circuit::Native
        { failure_window_secs: FAILURE_WINDOW.to_f, half_open_timeout_secs: COOLDOWN, auto_register: false }
      else
        { failure_window: FAILURE_WINDOW, reset_timeout: COOLDOWN, reset_timeout_jitter: 0 }
      end
    )
    klass.new("recovery_#{SecureRandom.hex(4)}", options)
  end

  # Twice the cooldown: `sleep` waits at least that long, so it has elapsed.
  def wait_for_cooldown
    sleep(COOLDOWN * 2)
  end
end
