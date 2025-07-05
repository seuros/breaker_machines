# frozen_string_literal: true

class BattleShip < BaseShip
  attr_reader :weapon_systems, :shield_strength

  def initialize(name, registry_number)
    super
    @weapon_systems = %i[phasers photon_torpedoes quantum_torpedoes]
    @shield_strength = 100
  end

  # Battle-specific circuits
  circuit :weapons do
    threshold failures: 2, within: 30
    reset_after 20

    fallback { engage_backup_weapons }

    on_open { log_event('WARNING: Weapons systems offline!') }
    on_close { log_event('Weapons systems restored') }
  end

  circuit :shields do
    threshold failures: 1, within: 60 # Very sensitive - one hit could be critical
    reset_after 45
    timeout 2

    fallback { divert_power_to_hull_plating }

    on_open { log_event('RED ALERT: Shields down!') }
    on_half_open { log_event('Attempting shield restoration...') }
  end

  circuit :targeting_computer do
    threshold failures: 3, within: 45
    reset_after 30
    timeout 1 # Must be fast in battle

    fallback { use_manual_targeting }
  end

  # Override navigation for tactical maneuvers
  circuit :navigation do
    threshold failures: 10, within: 120 # More tolerant during battle
    reset_after 15 # Faster recovery needed
    timeout 2

    fallback { engage_evasive_pattern }

    on_open { log_event('Tactical navigation offline - evasive maneuvers only!') }
  end

  def fire_phasers(target)
    circuit(:weapons).wrap do
      circuit(:targeting_computer).wrap do
        @shield_strength -= 2 # Firing drains shields slightly
        "Phasers fired at #{target} - Direct hit!"
      end
    end
  end

  def fire_torpedoes(target, type = :photon)
    circuit(:weapons).wrap do
      raise 'Invalid torpedo type' unless @weapon_systems.include?(:"#{type}_torpedoes")

      "#{type.to_s.capitalize} torpedoes launched at #{target}"
    end
  end

  def raise_shields
    circuit(:shields).wrap do
      @shield_strength = 100
      'Shields at maximum strength'
    end
  end

  def tactical_analysis(enemy_ship)
    circuit(:targeting_computer).wrap do
      "Analysis complete: #{enemy_ship} shows weakness in aft shields"
    end
  end

  protected

  def engage_backup_weapons
    log_event('Switching to backup weapon systems')
    'Manual weapons control engaged'
  end

  def divert_power_to_hull_plating
    log_event('Diverting power to ablative hull plating')
    'Hull plating reinforced - 30% protection'
  end

  def use_manual_targeting
    log_event('Manual targeting engaged')
    'Targeting manually - accuracy reduced'
  end

  def engage_evasive_pattern
    log_event('Executing evasive pattern Delta-5')
    'Evasive maneuvers engaged'
  end
end
