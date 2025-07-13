# frozen_string_literal: true

require 'test_helper'

class StarfleetBattleCruiserTest < ActiveSupport::TestCase
  setup do
    # Clear any existing circuit instances
    BreakerMachines.registry.clear if BreakerMachines.registry.respond_to?(:clear)

    @cruiser = StarfleetBattleCruiser.create!(
      name: 'USS Enterprise',
      registry: 'NCC-1701-D',
      captain: 'Jean-Luc Picard'
    )
  end

  teardown do
    # Reset all circuits and clear instance cache
    if @cruiser
      @cruiser.reset_all_circuits
      @cruiser.instance_variable_set(:@circuit_instances, nil)
    end
    # Clear registry again
    BreakerMachines.registry.clear if BreakerMachines.registry.respond_to?(:clear)
  end

  test 'warp core failure cascades to dependent systems' do
    # All systems should start operational
    assert @cruiser.circuit(:warp_core).closed?
    assert @cruiser.circuit(:shields).closed?
    assert @cruiser.circuit(:weapons).closed?
    assert @cruiser.circuit(:life_support).closed?
    assert @cruiser.circuit(:navigation).closed?

    # Simulate warp core failures
    2.times do
      @cruiser.circuit(:warp_core).call { raise 'Warp core breach!' }
    rescue StandardError
      # Expected
    end

    # Warp core and all dependent systems should be open
    assert @cruiser.circuit(:warp_core).open?
    assert @cruiser.circuit(:shields).open?
    assert @cruiser.circuit(:weapons).open?
    assert @cruiser.circuit(:life_support).open?
    assert @cruiser.circuit(:navigation).open?

    # Battle status should change to red alert
    assert_equal 'red', @cruiser.battle_status
  end

  test 'main computer failure affects only its dependent systems' do
    # Simulate main computer failures
    3.times do
      @cruiser.circuit(:main_computer).call { raise 'Computer core malfunction!' }
    rescue StandardError
      # Expected
    end

    # Main computer and its dependents should be open
    assert @cruiser.circuit(:main_computer).open?
    assert @cruiser.circuit(:targeting_computer).open?
    assert @cruiser.circuit(:navigation).open?
    assert @cruiser.circuit(:communications).open?

    # But shields and weapons should remain closed (not dependent on main computer)
    assert @cruiser.circuit(:shields).closed?
    assert @cruiser.circuit(:weapons).closed?
  end

  test 'hull integrity breach triggers abandon ship protocols' do
    # Simulate hull damage
    5.times do
      @cruiser.circuit(:hull_integrity).call { raise 'Hull breach!' }
    rescue StandardError
      # Expected
    end

    # Hull integrity and dependent systems should be open
    assert @cruiser.circuit(:hull_integrity).open?
    assert @cruiser.circuit(:life_support).open?
    assert @cruiser.circuit(:structural_integrity).open?

    # Battle status should be critical
    assert_equal 'critical', @cruiser.battle_status
  end

  test 'battle damage assessment tracks circuit states' do
    # Cause some failures
    2.times do
      @cruiser.circuit(:shields).call { raise 'Shield failure!' }
    rescue StandardError
      # Expected
    end

    damage_report = @cruiser.assess_battle_damage

    assert damage_report[:shields]
    assert_equal 2, damage_report[:shields][:failure_count]
    assert damage_report[:shields][:operational]

    # Now cause enough failures to open the circuit
    8.times do
      @cruiser.circuit(:shields).call { raise 'Shield failure!' }
    rescue StandardError
      # Expected
    end

    damage_report = @cruiser.assess_battle_damage
    refute damage_report[:shields][:operational]
    assert_equal :open, damage_report[:shields][:status]
  end

  test 'emergency protocols handle affected circuits' do
    # Mock the cruiser to track method calls
    def @cruiser.divert_power_to_shields
      @shields_diverted = true
      super
    end

    def @cruiser.shields_diverted?
      @shields_diverted
    end

    # Trigger warp core failure
    2.times do
      @cruiser.circuit(:warp_core).call { raise 'Warp core breach!' }
    rescue StandardError
      # Expected
    end

    # Emergency protocol should have been executed
    assert @cruiser.shields_diverted?
  end

  test 'cascading failures can be reset' do
    # Cause cascading failure
    2.times do
      @cruiser.circuit(:warp_core).call { raise 'Warp core breach!' }
    rescue StandardError
      # Expected
    end

    # All circuits should be open
    assert @cruiser.circuit(:warp_core).open?
    assert @cruiser.circuit(:shields).open?

    # Reset all circuits
    @cruiser.reset_all_circuits

    # All circuits should be closed again
    assert @cruiser.circuit(:warp_core).closed?
    assert @cruiser.circuit(:shields).closed?
  end

  test 'ship operations use circuit breakers' do
    # Normal operation should work
    def @cruiser.warp_core_temperature
      8000
    end
    assert_nothing_raised { @cruiser.engage_warp_drive }

    # High temperature should fail
    def @cruiser.warp_core_temperature
      9500
    end
    assert_raises(StandardError) { @cruiser.engage_warp_drive }

    # After enough failures, circuit should open
    assert_raises(BreakerMachines::CircuitOpenError) do
      2.times { @cruiser.engage_warp_drive rescue nil }
      @cruiser.engage_warp_drive
    end
  end

  test 'multiple cascading failures trigger correct emergency protocols' do
    protocols_called = []

    # Override emergency protocol methods to track calls
    @cruiser.define_singleton_method(:red_alert) do |circuits|
      protocols_called << [:red_alert, circuits]
      super(circuits)
    end

    @cruiser.define_singleton_method(:backup_systems_engage) do |circuits|
      protocols_called << [:backup_systems_engage, circuits]
      super(circuits)
    end

    # Trigger warp core failure
    2.times do
      @cruiser.circuit(:warp_core).call { raise 'Warp core breach!' }
    rescue StandardError
      # Expected
    end

    # Trigger main computer failure
    3.times do
      @cruiser.circuit(:main_computer).call { raise 'Computer malfunction!' }
    rescue StandardError
      # Expected
    end

    # Both emergency protocols should have been called
    assert protocols_called.any? { |p| p[0] == :red_alert }
    assert protocols_called.any? { |p| p[0] == :backup_systems_engage }
  end

  test 'critical damage assessment from multiple system failures' do
    # Start in green status
    assert_equal 'green', @cruiser.battle_status

    # Damage warp core
    2.times do
      @cruiser.circuit(:warp_core).call { raise 'Warp core breach!' }
    rescue StandardError
      # Expected
    end

    @cruiser.assess_battle_damage
    assert_equal 'critical', @cruiser.battle_status

    # Now damage hull integrity too
    5.times do
      @cruiser.circuit(:hull_integrity).call { raise 'Hull breach!' }
    rescue StandardError
      # Expected
    end

    @cruiser.assess_battle_damage
    assert_equal 'critical', @cruiser.battle_status
  end

  test 'fallback values work for dependent circuits' do
    # Cause shields to fail through cascade
    2.times do
      @cruiser.circuit(:warp_core).call { raise 'Warp core breach!' }
    rescue StandardError
      # Expected
    end

    # Shield circuit should be open but fallback should work
    assert @cruiser.circuit(:shields).open?

    result = @cruiser.circuit(:shields).call { 'Normal shields' }
    assert_equal 'Emergency force fields activated', result
  end
end
