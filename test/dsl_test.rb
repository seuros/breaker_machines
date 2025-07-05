# frozen_string_literal: true

require 'test_helper'

class TestDSL < ActiveSupport::TestCase
  class SpaceStation
    include BreakerMachines::DSL

    circuit :life_support do
      threshold failures: 2, within: 30
      reset_after 15

      fallback { 'Emergency oxygen activated' }

      on_open do
        @alerts ||= []
        @alerts << 'Life support offline!'
      end
    end

    circuit :shields do
      threshold failures: 1
      timeout 5.seconds

      handle StandardError, SystemCallError
    end

    def activate_life_support
      circuit(:life_support).wrap do
        'Life support online'
      end
    end

    def raise_shields
      circuit(:shields).wrap do
        'Shields at 100%'
      end
    end

    def alerts
      @alerts ||= []
    end
  end

  def setup
    @station = SpaceStation.new
  end

  def test_dsl_creates_circuit_configuration
    assert SpaceStation.circuits.key?(:life_support)
    assert SpaceStation.circuits.key?(:shields)

    life_support_config = SpaceStation.circuits[:life_support]

    assert_equal 2, life_support_config[:failure_threshold]
    assert_equal 30, life_support_config[:failure_window]
    assert_equal 15, life_support_config[:reset_timeout]
    assert life_support_config[:fallback]
    assert life_support_config[:on_open]
  end

  def test_circuit_instances_are_cached
    circuit1 = @station.circuit(:life_support)
    circuit2 = @station.circuit(:life_support)

    assert_same circuit1, circuit2
  end

  def test_successful_operation
    result = @station.activate_life_support

    assert_equal 'Life support online', result

    result = @station.raise_shields

    assert_equal 'Shields at 100%', result
  end

  def test_fallback_execution
    # Force circuit to fail 2 times to trip it
    life_support = @station.circuit(:life_support)
    2.times do
      life_support.wrap { raise 'Life support malfunction' }
    rescue StandardError
      nil
    end

    # Circuit should be open now and use fallback
    result = @station.activate_life_support

    assert_equal 'Emergency oxygen activated', result
  end

  def test_callbacks_via_dsl
    # Trigger failures
    life_support = @station.circuit(:life_support)

    2.times do
      life_support.wrap { raise 'Life support malfunction' }
    rescue StandardError
      nil
    end

    assert_includes @station.alerts, 'Life support offline!'
  end

  def test_timeout_configuration_with_activesupport_duration
    shields_config = SpaceStation.circuits[:shields]

    assert_equal 5, shields_config[:timeout]
  end

  class MultiSystemShip
    include BreakerMachines::DSL

    circuit :hyperdrive do
      threshold failures: 3
    end

    circuit :teleporter do
      threshold failures: 5
    end

    circuit :cloaking_device do
      threshold failures: 1
      reset_after 60
    end
  end

  def test_multiple_circuits_per_class
    assert_equal 3, MultiSystemShip.circuits.count
    assert MultiSystemShip.circuits.key?(:hyperdrive)
    assert MultiSystemShip.circuits.key?(:teleporter)
    assert MultiSystemShip.circuits.key?(:cloaking_device)
  end

  class RedundantSystem
    include BreakerMachines::DSL

    circuit :main_computer do
      fallback { 'Backup computer' }
      fallback { 'Manual override' }
    end

    def compute
      circuit(:main_computer).wrap { 'Main computer online' }
    end
  end

  def test_chained_fallbacks
    config = RedundantSystem.circuits[:main_computer]

    # Verify fallbacks are stored as array
    assert_kind_of Array, config[:fallback]
    assert_equal 2, config[:fallback].length
  end

  def test_exception_handling_configuration
    shields_config = SpaceStation.circuits[:shields]

    assert_includes shields_config[:exceptions], StandardError
    assert_includes shields_config[:exceptions], SystemCallError
  end
end
