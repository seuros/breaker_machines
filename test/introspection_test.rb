# frozen_string_literal: true

require 'test_helper'

class IntrospectionTest < ActiveSupport::TestCase
  class DiagnosticModule
    include BreakerMachines::DSL

    circuit :sensor_array do
      threshold failures: 2, within: 10
      fallback 'Backup sensors engaged'
    end

    circuit :critical_system do
      threshold failures: 2, within: 10
      # No fallback - will raise errors
    end

    circuit :telemetry_link do
      threshold failures: 3
      reset_after 5
    end

    def scan_sector(&)
      circuit(:sensor_array).call(&)
    end

    def transmit_data(&)
      circuit(:telemetry_link).call(&)
    end

    def critical_operation(&)
      circuit(:critical_system).call(&)
    end
  end

  def setup
    # Clear registry first
    BreakerMachines::Registry.instance.clear

    # Reset at class level to catch any prior instances
    DiagnosticModule.reset_all_circuits

    # Create fresh instance
    @module = DiagnosticModule.new
  end

  def test_circuit_stats
    circuit = @module.circuit(:sensor_array)
    stats = circuit.stats

    assert_equal :closed, stats.state
    assert_equal 0, stats.failure_count
    assert_equal 0, stats.success_count
    assert_nil stats.last_failure_at
    assert_nil stats.opened_at
  end

  def test_circuit_configuration
    circuit = @module.circuit(:sensor_array)
    config = circuit.configuration

    assert_equal 2, config[:failure_threshold]
    assert_equal 10, config[:failure_window]
    assert_equal 'Backup sensors engaged', config[:fallback]
  end

  def test_circuit_summary
    circuit = @module.circuit(:sensor_array)
    summary = circuit.summary

    assert_match(/Circuit 'sensor_array' is CLOSED/, summary)
    assert_match(/0 failures recorded/, summary)
  end

  def test_circuit_to_h
    circuit = @module.circuit(:sensor_array)
    data = circuit.to_h

    assert_equal :sensor_array, data[:name]
    assert_equal :closed, data[:state]
    assert_kind_of Hash, data[:stats]
    assert_kind_of Hash, data[:config]
    assert_kind_of Array, data[:event_log]
  end

  def test_last_error_tracking
    circuit = @module.circuit(:critical_system)

    # Trigger failures
    2.times do
      assert_raises(RuntimeError) do
        @module.critical_operation { raise 'Sensor malfunction' }
      end
    end

    error_info = circuit.last_error_info

    assert_equal 'RuntimeError', error_info.error_class
    assert_equal 'Sensor malfunction', error_info.message
    assert_kind_of Float, error_info.occurred_at
  end

  def test_event_logging
    circuit = @module.circuit(:critical_system)

    # Generate some events
    @module.critical_operation { 'success' }

    assert_raises(RuntimeError) do
      @module.critical_operation { raise 'Error' }
    end

    events = circuit.event_log(limit: 10)

    # Event log is available with our storage backends
    skip unless events&.any?

    assert_equal 2, events.size
    assert_equal :success, events.first[:type]
    assert_equal :failure, events.last[:type]
  end

  def test_class_level_circuit_definitions
    definitions = DiagnosticModule.circuit_definitions

    assert_kind_of Hash, definitions
    assert_includes definitions.keys, :sensor_array
    assert_includes definitions.keys, :telemetry_link

    # Should not include sensitive data
    refute definitions[:sensor_array].key?(:owner)
    refute definitions[:sensor_array].key?(:storage)
  end

  def test_instance_level_introspection
    circuits = @module.circuit_instances

    assert_kind_of Hash, circuits

    # Access circuits to initialize them
    @module.circuit(:sensor_array)
    @module.circuit(:telemetry_link)

    assert_equal 2, @module.circuit_instances.size

    summary = @module.circuits_summary

    assert_kind_of Hash, summary
    assert_match(/CLOSED/, summary[:sensor_array])
    assert_match(/CLOSED/, summary[:telemetry_link])
  end

  def test_registry_tracking
    # Create multiple instances
    module1 = DiagnosticModule.new
    module2 = DiagnosticModule.new

    # Access circuits to register them
    circuit1 = module1.circuit(:sensor_array)
    circuit2 = module2.circuit(:sensor_array)

    registry = BreakerMachines::Registry.instance
    all_circuits = registry.all_circuits

    assert_includes all_circuits, circuit1
    assert_includes all_circuits, circuit2

    # Test find by name
    sensor_circuits = registry.find_by_name(:sensor_array)

    assert_equal 2, sensor_circuits.size
  end

  def test_registry_stats_summary
    module1 = DiagnosticModule.new
    module1.circuit(:sensor_array)
    module1.circuit(:telemetry_link)

    stats = BreakerMachines::Registry.instance.stats_summary

    assert_equal 2, stats[:total]
    assert_equal 2, stats[:by_state][:closed]
    assert_includes stats[:by_name].keys, :sensor_array
    assert_includes stats[:by_name].keys, :telemetry_link
  end

  def test_summary_for_different_states
    circuit = @module.circuit(:critical_system)

    # Test closed state
    assert_match(/CLOSED/, circuit.summary)

    # Open the circuit
    2.times do
      assert_raises(RuntimeError) do
        @module.critical_operation { raise 'Error' }
      end
    end

    # Test open state
    summary = circuit.summary

    assert_match(/OPEN until/, summary)
    assert_match(/after 2 failures/, summary)
    assert_match(/RuntimeError/, summary)
  end
end
