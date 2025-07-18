# frozen_string_literal: true

require 'test_helper'

# Load dummy app models in correct order
require_relative 'dummy/app/models/base_ship'
require_relative 'dummy/app/models/battle_ship'
require_relative 'dummy/app/models/cargo_ship'
require_relative 'dummy/app/models/science_vessel'
require_relative 'dummy/app/models/rmns_atlas_monkey'

class DummyShipsTest < ActiveSupport::TestCase
  def setup
    @base_ship = BaseShip.new('USS Foundation', 'NCC-0001')
    @battle_ship = BattleShip.new('USS Warrior', 'NCC-1701-D')
    @cargo_ship = CargoShip.new('USS Merchant', 'NCC-4747', 100_000)
    @science_vessel = ScienceVessel.new('USS Discovery', 'NCC-3142')
  end

  def test_all_ships_have_base_circuits
    ships = [@base_ship, @battle_ship, @cargo_ship, @science_vessel]

    ships.each do |ship|
      assert_respond_to ship, :activate_life_support
      assert_respond_to ship, :calculate_course
      assert_respond_to ship, :send_message

      # All should have base circuits
      assert ship.circuit(:life_support)
      assert ship.circuit(:navigation)
      assert ship.circuit(:communications)
    end
  end

  def test_battle_ship_has_combat_circuits
    # Battle ship specific
    assert_respond_to @battle_ship, :fire_phasers
    assert_respond_to @battle_ship, :raise_shields

    # Has additional circuits
    assert @battle_ship.circuit(:weapons)
    assert @battle_ship.circuit(:shields)
    assert @battle_ship.circuit(:targeting_computer)

    # Other ships don't have weapons
    assert_raises(NoMethodError) { @cargo_ship.fire_phasers('enemy') }
    assert_raises(NoMethodError) { @science_vessel.fire_phasers('enemy') }
  end

  def test_cargo_ship_has_cargo_circuits
    # Cargo specific
    assert_respond_to @cargo_ship, :load_cargo
    assert_respond_to @cargo_ship, :refrigerate_cargo

    # Has cargo circuits
    assert @cargo_ship.circuit(:cargo_bay)
    assert @cargo_ship.circuit(:refrigeration)
    assert @cargo_ship.circuit(:docking_clamps)

    # Other ships don't have cargo operations
    assert_raises(NoMethodError) { @battle_ship.load_cargo({}) }
    assert_raises(NoMethodError) { @science_vessel.refrigerate_cargo }
  end

  def test_science_vessel_has_research_circuits
    # Science specific
    assert_respond_to @science_vessel, :scan_anomaly
    assert_respond_to @science_vessel, :launch_probe

    # Has research circuits
    assert @science_vessel.circuit(:sensor_array)
    assert @science_vessel.circuit(:laboratory)
    assert @science_vessel.circuit(:probe_launcher)
    assert @science_vessel.circuit(:containment_field)
  end

  def test_circuit_overrides_work
    # CargoShip overrides life_support with different thresholds
    cargo_life_support = @cargo_ship.class.circuits[:life_support]
    base_life_support = @base_ship.class.circuits[:life_support]

    assert_equal 5, cargo_life_support[:failure_threshold]
    assert_equal 2, base_life_support[:failure_threshold]

    # BattleShip overrides navigation for tactical needs
    battle_nav = @battle_ship.class.circuits[:navigation]
    base_nav = @base_ship.class.circuits[:navigation]

    assert_equal 10, battle_nav[:failure_threshold] # More tolerant
    assert_equal 5, base_nav[:failure_threshold]
    assert_equal 15, battle_nav[:reset_timeout] # Faster recovery
    assert_equal 45, base_nav[:reset_timeout]
  end

  def test_circuit_independence_across_ships
    # Reset all circuits to ensure clean state
    BreakerMachines.reset!
    
    # Cause battle ship's weapons to fail
    3.times do
      @battle_ship.circuit(:weapons).wrap { raise 'Weapons malfunction' }
    rescue StandardError
      nil
    end

    assert_predicate @battle_ship.circuit(:weapons), :open?

    # Create a new battle ship - should have working weapons
    new_battle_ship = BattleShip.new('USS Enterprise', 'NCC-1701-E')

    assert_predicate new_battle_ship.circuit(:weapons), :closed?

    # Original still has failed weapons
    assert_equal 'Manual weapons control engaged', @battle_ship.fire_phasers('Borg Cube')
    assert_match(/Phasers fired/, new_battle_ship.fire_phasers('Borg Cube'))
  end

  def test_combat_scenario
    # Simulate battle damage

    # Shields take a hit
    begin
      @battle_ship.circuit(:shields).wrap { raise 'Shield generator damaged!' }
    rescue StandardError
      nil
    end

    # Should fall back to hull plating
    result = @battle_ship.raise_shields

    assert_equal 'Hull plating reinforced - 30% protection', result

    # Weapons still work
    result = @battle_ship.fire_phasers('Romulan Warbird')

    assert_match(/Phasers fired/, result)

    # But if targeting computer fails during battle...
    3.times do
      @battle_ship.circuit(:targeting_computer).wrap { raise 'Targeting sensors damaged!' }
    rescue StandardError
      nil
    end

    # Weapons still fire but with manual targeting
    result = @battle_ship.fire_phasers('Romulan Warbird')

    assert_equal 'Targeting manually - accuracy reduced', result
  end

  def test_cargo_operations
    manifest1 = { id: 1, description: 'Medical supplies', weight: 1000, perishable: true }
    manifest2 = { id: 2, description: 'Dilithium crystals', weight: 500, perishable: false }

    # Load cargo
    result = @cargo_ship.load_cargo(manifest1)

    assert_match(/Medical supplies.*1000 tons/, result)

    result = @cargo_ship.load_cargo(manifest2)

    assert_match(/Dilithium crystals.*500 tons/, result)

    # Check manifest
    manifest = @cargo_ship.cargo_manifest

    assert_equal 1500, manifest[:total_weight]
    assert_equal 2, manifest[:item_count]
    assert_in_delta(1.5, manifest[:capacity_used])

    # Refrigeration for perishables
    result = @cargo_ship.refrigerate_cargo

    assert_equal 'Refrigerating 1 perishable items at -20°C', result
  end

  def test_science_operations_with_safety
    # Normal probe launch
    result = @science_vessel.launch_probe('Unknown nebula')

    assert_match(/probe launched.*19 probes remaining/, result)

    # Dangerous experiment requires containment
    result = @science_vessel.conduct_experiment('Omega particle synthesis', :quantum_mechanics)

    assert_match(/Experiment.*completed in quantum_mechanics lab/, result)

    # If containment fails, emergency protocol
    begin
      @science_vessel.circuit(:containment_field).wrap { raise 'Containment breach!' }
    rescue StandardError
      nil
    end

    result = @science_vessel.establish_containment(5)

    assert_equal 'All samples ejected to space - laboratory sealed', result
  end

  def test_cascading_circuit_failures
    # Reset to ensure clean state
    BreakerMachines.reset!
    
    # Science vessel sensor failure affects experiments
    begin
      @science_vessel.circuit(:sensor_array).wrap { raise 'Sensor overload' }
    rescue StandardError
      nil
    end

    # Can still do basic experiments (laboratory circuit is still closed)
    result = @science_vessel.conduct_experiment('Basic chemistry')

    assert_match(/completed/, result)

    # But can't analyze samples (needs sensors)
    result = @science_vessel.analyze_sample('XB-1')

    assert_equal 'Basic sensors only - 20% effectiveness', result
  end
end
