# frozen_string_literal: true

require_relative '../lib/breaker_machines'

# Example: Starship Systems with Cascading Circuit Breakers
#
# This example demonstrates how cascading circuit breakers can model
# complex system dependencies, like those found in a starship where
# a critical system failure can cascade to dependent systems.

class StarshipSystems
  include BreakerMachines::DSL

  # Main power system - failure cascades to all power-dependent systems
  cascade_circuit :main_power do
    threshold failures: 2, within: 30.seconds
    cascades_to :shields, :weapons, :life_support, :navigation, :communications
    emergency_protocol :emergency_power_redirect

    on_cascade do |affected_circuits|
      puts "[ALERT] Main power failure! Affected systems: #{affected_circuits.join(', ')}"
    end
  end

  # Warp core - failure cascades to propulsion and structural systems
  cascade_circuit :warp_core do
    threshold failures: 3, within: 60.seconds
    cascades_to :warp_drive, :structural_integrity, :inertial_dampeners
    emergency_protocol :warp_core_ejection_protocol

    on_open do
      puts "[CRITICAL] Warp core breach detected!"
    end
  end

  # Computer core - failure affects all automated systems
  cascade_circuit :computer_core do
    threshold failures: 5, within: 120.seconds
    cascades_to :targeting_system, :navigation, :sensors, :transporters
    emergency_protocol :manual_override_engaged
  end

  # Define dependent systems
  circuit :shields do
    threshold failures: 10, within: 60.seconds
    fallback { activate_emergency_force_fields }
  end

  circuit :weapons do
    threshold failures: 5, within: 30.seconds
    fallback { enable_manual_targeting }
  end

  circuit :life_support do
    threshold failures: 3, within: 120.seconds
    fallback { deploy_emergency_oxygen }
  end

  circuit :navigation do
    threshold failures: 8, within: 60.seconds
    fallback { switch_to_stellar_cartography }
  end

  circuit :communications do
    threshold failures: 10, within: 120.seconds
    fallback { activate_emergency_beacon }
  end

  circuit :warp_drive do
    threshold failures: 5, within: 60.seconds
  end

  circuit :structural_integrity do
    threshold failures: 5, within: 60.seconds
  end

  circuit :inertial_dampeners do
    threshold failures: 5, within: 60.seconds
  end

  circuit :targeting_system do
    threshold failures: 5, within: 30.seconds
  end

  circuit :sensors do
    threshold failures: 10, within: 120.seconds
  end

  circuit :transporters do
    threshold failures: 5, within: 60.seconds
  end

  # Emergency protocols
  def emergency_power_redirect(affected_circuits)
    puts "[EMERGENCY] Redirecting auxiliary power..."
    affected_circuits.each do |circuit_name|
      puts "  - Attempting to restore #{circuit_name}"
    end
  end

  def warp_core_ejection_protocol(affected_circuits)
    puts "[EMERGENCY] Initiating warp core ejection sequence!"
    puts "  - Sealing blast doors"
    puts "  - Preparing ejection mechanism"
    puts "  - All hands brace for impact!"
  end

  def manual_override_engaged(affected_circuits)
    puts "[EMERGENCY] Computer core offline - manual control engaged"
    affected_circuits.each do |circuit_name|
      puts "  - #{circuit_name}: Switching to manual control"
    end
  end

  # Fallback methods
  def activate_emergency_force_fields
    puts "  - Emergency force fields activated"
    "Emergency shields at 20% capacity"
  end

  def enable_manual_targeting
    puts "  - Manual targeting enabled"
    "Weapons on manual control"
  end

  def deploy_emergency_oxygen
    puts "  - Emergency oxygen deployed"
    "Life support on backup - 4 hours remaining"
  end

  def switch_to_stellar_cartography
    puts "  - Stellar cartography navigation engaged"
    "Navigation by star charts"
  end

  def activate_emergency_beacon
    puts "  - Emergency beacon activated"
    "Distress signal broadcasting"
  end

  # System operations
  def raise_shields
    circuit(:shields).call do
      puts "Raising shields..."
      # Simulate shield activation
      raise "Shield generator overload!" if rand > 0.8
      "Shields at 100%"
    end
  end

  def fire_phasers
    circuit(:weapons).call do
      circuit(:targeting_system).call do
        puts "Locking on target..."
        raise "Targeting computer malfunction!" if rand > 0.9
        "Phasers fired!"
      end
    end
  end

  def engage_warp
    circuit(:warp_core).call do
      circuit(:warp_drive).call do
        puts "Engaging warp drive..."
        raise "Warp core containment failure!" if rand > 0.95
        "Warp 5 engaged"
      end
    end
  end

  def scan_sector
    circuit(:sensors).call do
      puts "Scanning sector..."
      raise "Sensor array offline!" if rand > 0.85
      "Scan complete - no threats detected"
    end
  end

  # Status report
  def status_report
    puts "\n=== STARSHIP SYSTEMS STATUS ==="
    circuits_summary.each do |name, summary|
      puts summary
    end
    puts "==============================\n"
  end

  # Damage report with cascade tracking
  def damage_report
    report = { operational: [], damaged: [], critical: [] }

    circuit_instances.each do |name, circuit|
      case circuit.status_name
      when :closed
        report[:operational] << name
      when :half_open
        report[:damaged] << name
      when :open
        report[:critical] << name
      end
    end

    puts "\n=== DAMAGE REPORT ==="
    puts "Operational Systems: #{report[:operational].join(', ')}"
    puts "Damaged Systems: #{report[:damaged].join(', ')}"
    puts "Critical Failures: #{report[:critical].join(', ')}"
    puts "==================\n"

    report
  end
end

# Example usage
if __FILE__ == $0
  ship = StarshipSystems.new

  puts "=== STARSHIP SYSTEMS DEMONSTRATION ===\n\n"

  # Normal operations
  puts "1. Normal Operations:"
  puts ship.raise_shields
  puts ship.scan_sector

  # Simulate some failures
  puts "\n2. Simulating system failures:"
  5.times do |i|
    begin
      puts "\nAttempt #{i + 1}:"
      ship.circuit(:computer_core).call { raise "Memory bank failure!" }
    rescue => e
      puts "  Error: #{e.message}"
    end
  end

  # Check cascade effect
  puts "\n3. Checking cascade effects:"
  ship.damage_report

  # Try to use affected systems
  puts "\n4. Attempting to use cascaded systems:"
  begin
    ship.circuit(:targeting_system).call { "Targeting..." }
  rescue BreakerMachines::CircuitOpenError => e
    puts "  Targeting system unavailable: #{e.message}"
  end

  # Status report
  puts "\n5. Full status report:"
  ship.status_report

  # Simulate main power failure
  puts "\n6. Simulating main power failure:"
  2.times do
    begin
      ship.circuit(:main_power).call { raise "Power conduit explosion!" }
    rescue => e
      puts "  Error: #{e.message}"
    end
  end

  # Final damage report
  puts "\n7. Final damage assessment:"
  ship.damage_report

  puts "\n=== END DEMONSTRATION ===\n"
end
