# frozen_string_literal: true

class StarfleetBattleCruiser < ApplicationRecord
  include BreakerMachines::DSL

  # Main systems with cascading failures
  cascade_circuit :warp_core do
    threshold failures: 2, within: 30.seconds
    cascades_to :shields, :weapons, :life_support, :navigation
    emergency_protocol :red_alert
    on_cascade do |affected_circuits|
      Rails.logger.warn "[WARP CORE BREACH] Cascading failure affecting: #{affected_circuits.join(', ')}"
    end
  end

  cascade_circuit :main_computer do
    threshold failures: 3, within: 60.seconds
    cascades_to :targeting_computer, :navigation, :communications
    emergency_protocol :backup_systems_engage
  end

  cascade_circuit :hull_integrity do
    threshold failures: 5, within: 120.seconds
    cascades_to :life_support, :structural_integrity
    emergency_protocol :abandon_ship_protocols
  end

  # Dependent systems
  circuit :shields do
    threshold failures: 10, within: 60.seconds
    fallback { 'Emergency force fields activated' }
  end

  circuit :weapons do
    threshold failures: 5, within: 30.seconds
    fallback { 'Manual targeting engaged' }
  end

  circuit :life_support do
    threshold failures: 3, within: 120.seconds
    fallback { 'Emergency oxygen deployed' }
  end

  circuit :navigation do
    threshold failures: 8, within: 60.seconds
    fallback { 'Dead reckoning navigation' }
  end

  circuit :targeting_computer do
    threshold failures: 5, within: 30.seconds
  end

  circuit :communications do
    threshold failures: 10, within: 120.seconds
  end

  circuit :structural_integrity do
    threshold failures: 5, within: 60.seconds
  end

  circuit :fire_control do
    threshold failures: 5, within: 30.seconds
  end

  # State machine for battle readiness
  state_machine :battle_status, initial: :green do
    state :green
    state :yellow
    state :red
    state :critical

    event :raise_alert do
      transition green: :yellow, yellow: :red
    end

    event :critical_damage do
      transition green: :critical, yellow: :critical, red: :critical, critical: :critical
    end

    event :all_clear do
      transition any: :green
    end

    after_transition any => :red do |cruiser|
      cruiser.red_alert_engaged_at = Time.current
    end

    after_transition any => :critical do |cruiser|
      cruiser.critical_status_at = Time.current
    end
  end

  # Emergency protocols
  def red_alert(affected_circuits)
    # For warp core failure, go straight to red alert
    if green?
      raise_alert! # green -> yellow
      raise_alert! # yellow -> red
    elsif yellow?
      raise_alert! # yellow -> red
    end

    affected_circuits.each do |circuit_name|
      case circuit_name
      when :shields
        divert_power_to_shields
      when :life_support
        seal_hull_breaches
      when :weapons
        enable_manual_override
      end
    end

    captain_log "Red Alert! Systems affected: #{affected_circuits.join(', ')}"
  end

  def backup_systems_engage(affected_circuits)
    captain_log "Engaging backup systems for: #{affected_circuits.join(', ')}"

    affected_circuits.each do |circuit_name|
      case circuit_name
      when :navigation
        engage_stellar_cartography
      when :targeting_computer
        switch_to_manual_targeting
      when :communications
        deploy_subspace_beacon
      end
    end
  end

  def abandon_ship_protocols(_affected_circuits)
    critical_damage!
    captain_log 'CRITICAL: Hull breach! Abandon ship protocols initiated!'
    sound_evacuation_alarm
    launch_escape_pods
  end

  # Battle damage assessment
  def assess_battle_damage
    damage_report = {}

    # Check all circuits
    circuit_instances.each do |name, circuit|
      damage_report[name] = {
        status: circuit.status_name,
        operational: circuit.closed?,
        failure_count: circuit.stats.failure_count
      }
    end

    # Determine overall status
    critical_systems = %i[warp_core life_support hull_integrity]
    critical_failures = critical_systems.count { |sys| damage_report[sys] && !damage_report[sys][:operational] }

    if critical_failures >= 2
      critical_damage! unless critical?
    elsif critical_failures >= 1
      raise_alert! unless red? || critical?
    end

    damage_report
  end

  # Ship operations
  def engage_warp_drive
    circuit(:warp_core).call do
      raise 'Warp core offline!' if warp_core_temperature > 9000

      captain_log 'Engaging warp drive'
      update!(warp_engaged: true)
    end
  end

  def fire_phasers
    circuit(:weapons).call do
      circuit(:targeting_computer).call do
        raise 'Targeting computer malfunction!' if rand > 0.9

        captain_log 'Phasers fired!'
        decrement_phaser_banks
      end
    end
  end

  def raise_shields
    circuit(:shields).call do
      raise 'Shield generator overload!' if shield_strength < 10

      captain_log 'Shields raised'
      update!(shields_up: true)
    end
  end

  def hail_starfleet
    circuit(:communications).call do
      raise 'Subspace interference!' if in_nebula?

      captain_log 'Hailing Starfleet Command'
      transmit_message
    end
  end

  # Simulated ship systems
  def warp_core_temperature
    rand(7000..9500)
  end

  def shield_strength
    rand(0..100)
  end

  def in_nebula?
    rand > 0.8
  end

  def hull_damage_percentage
    rand(0..100)
  end

  private

  def captain_log(message)
    Rails.logger.info "[#{name}] #{message}"
  end

  def divert_power_to_shields
    captain_log 'Diverting auxiliary power to shields'
  end

  def seal_hull_breaches
    captain_log 'Emergency force fields sealing hull breaches'
  end

  def enable_manual_override
    captain_log 'Weapons systems on manual override'
  end

  def engage_stellar_cartography
    captain_log 'Stellar cartography engaged for navigation'
  end

  def switch_to_manual_targeting
    captain_log 'Manual targeting systems online'
  end

  def deploy_subspace_beacon
    captain_log 'Emergency subspace beacon deployed'
  end

  def sound_evacuation_alarm
    captain_log 'EVACUATION ALARM SOUNDING'
  end

  def launch_escape_pods
    captain_log 'Escape pods launching'
  end

  def decrement_phaser_banks
    # Simulate phaser usage
  end

  def transmit_message
    # Simulate message transmission
  end
end
