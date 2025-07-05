# frozen_string_literal: true

require 'test_helper'

class TestArrayFallback < ActiveSupport::TestCase
  class SpaceStation
    include BreakerMachines::DSL

    circuit :oxygen_system do
      threshold failures: 1
      fallback [
        ->(_error) { 'Emergency oxygen from reserve tank' },
        ->(_error) { 'Backup CO2 scrubbers activated' },
        ->(_error) { 'Opening emergency airlocks' }
      ]
    end

    circuit :power_grid do
      threshold failures: 1
      fallback [
        ->(_error) { raise 'Solar panels offline' },
        ->(_error) { raise 'Nuclear reactor offline' },
        ->(_error) { 'Emergency batteries activated' }
      ]
    end

    def activate_oxygen
      circuit(:oxygen_system).call { raise 'Primary oxygen generation failed' }
    end

    def activate_power
      circuit(:power_grid).call { raise 'Main power conduit destroyed' }
    end
  end

  def setup
    @station = SpaceStation.new
  end

  def test_array_fallback_returns_first_successful_result
    result = @station.activate_oxygen

    assert_equal 'Emergency oxygen from reserve tank', result
  end

  def test_array_fallback_tries_each_until_success
    result = @station.activate_power

    assert_equal 'Emergency batteries activated', result
  end

  def test_array_fallback_raises_if_all_fail
    station = SpaceStation.new
    station.instance_eval do
      self.class.circuit :life_support do
        threshold failures: 1
        fallback [
          ->(_error) { raise 'Backup 1 failed' },
          ->(_error) { raise 'Backup 2 failed' },
          ->(_error) { raise 'Backup 3 failed' }
        ]
      end

      def activate_life_support
        circuit(:life_support).call { raise 'Primary system offline' }
      end
    end

    assert_raises(RuntimeError) do
      station.activate_life_support
    end
  end

  def test_mixed_fallback_array
    station = SpaceStation.new
    station.instance_eval do
      self.class.circuit :communications do
        threshold failures: 1
        fallback [
          ->(_error) { raise 'Subspace relay damaged' },
          'Emergency beacon activated',
          ->(_error) { 'Should not reach here' }
        ]
      end

      def send_distress_signal
        circuit(:communications).call { raise 'Main antenna destroyed' }
      end
    end

    result = station.send_distress_signal

    assert_equal 'Emergency beacon activated', result
  end
end
