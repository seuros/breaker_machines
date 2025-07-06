# frozen_string_literal: true

require 'test_helper'

class TestInheritance < ActiveSupport::TestCase
  def test_base_class_circuits
    ship = BaseSpaceship.new

    assert_equal 'Engine started', ship.start_engine
    assert_equal 'Shields up', ship.raise_shields

    # Base class has 2 circuits
    assert_equal 2, BaseSpaceship.circuits.count
    assert BaseSpaceship.circuits.key?(:engine)
    assert BaseSpaceship.circuits.key?(:shields)
  end

  def test_fighter_inherits_and_extends_circuits
    fighter = Fighter.new

    # Can use inherited circuits
    assert_equal 'Engine started', fighter.start_engine
    assert_equal 'Shields up', fighter.raise_shields

    # Can use new circuit
    assert_equal 'Lasers fired', fighter.fire_lasers

    # Fighter has 3 circuits (2 inherited + 1 new)
    assert_equal 3, Fighter.circuits.count
    assert Fighter.circuits.key?(:engine)
    assert Fighter.circuits.key?(:shields)
    assert Fighter.circuits.key?(:weapons)
  end

  def test_cargo_ship_overrides_circuit_config
    cargo = CorellianFreighter.new

    # Engine circuit exists but with different config
    assert_equal 'Engine started', cargo.start_engine
    assert_equal 'Cargo loaded', cargo.load_cargo

    # Check that cargo ship has different engine config
    cargo_engine_config = CorellianFreighter.circuits[:engine]
    base_engine_config = BaseSpaceship.circuits[:engine]

    assert_equal 5, cargo_engine_config[:failure_threshold]
    assert_equal 3, base_engine_config[:failure_threshold]

    # Different fallback messages
    assert_equal 'Auxiliary thrusters', cargo_engine_config[:fallback].call
    assert_equal 'Emergency power', base_engine_config[:fallback].call
  end

  def test_circuit_instances_are_independent
    fighter = Fighter.new
    cargo = CorellianFreighter.new

    # Open fighter's engine circuit
    3.times do
      fighter.circuit(:engine).wrap { raise 'Engine failure' }
    rescue StandardError
      nil
    end

    assert_predicate fighter.circuit(:engine), :open?
    assert_predicate cargo.circuit(:engine), :closed? # Cargo ship's engine still works

    # Fighter gets fallback, cargo still works normally
    assert_equal 'Emergency power', fighter.start_engine
    assert_equal 'Engine started', cargo.start_engine
  end

  def test_subclass_specific_circuits
    explorer = ExplorerShip.new
    fighter = Fighter.new

    # Explorer has scanner, fighter doesn't
    assert_respond_to explorer, :scan_planet
    refute_respond_to fighter, :scan_planet

    # Fighter has weapons, explorer doesn't
    assert_respond_to fighter, :fire_lasers
    refute_respond_to explorer, :fire_lasers

    # Both have base circuits
    assert_respond_to explorer, :start_engine
    assert_respond_to fighter, :start_engine
  end

  def test_circuit_isolation_across_inheritance_tree
    base = BaseSpaceship.new
    fighter = Fighter.new
    cargo = CorellianFreighter.new

    # Open shields on fighter
    5.times do
      fighter.circuit(:shields).wrap { raise 'Shield failure' }
    rescue StandardError
      nil
    end

    assert_predicate fighter.circuit(:shields), :open?
    assert_predicate base.circuit(:shields), :closed?
    assert_predicate cargo.circuit(:shields), :closed?
  end
end
