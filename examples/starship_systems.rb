# frozen_string_literal: true

# A starship's systems as circuits: the subspace network cascades to the
# weapons and sensors, the helm depends on the reactor, and the shields hedge
# across two emitters. Run with `bundle exec ruby -Ilib examples/starship_systems.rb`.
require 'breaker_machines'

SECOND = 1_000_000_000
B = BreakerMachines
POLICY = B::Policy.new(B::Threshold.new(2, nil, 0), 60 * SECOND, B::Recovery.new(5 * SECOND, 0.1, 1, 1), nil)

class Starship
  include BreakerMachines::DSL

  circuit(:weapons) { policy POLICY }
  circuit(:sensors) { policy POLICY }

  cascade_circuit :network do
    policy POLICY
    cascades_to :weapons, :sensors
    emergency_protocol :red_alert
  end

  circuit :shields do
    policy POLICY
    backends -> { raise IOError, 'forward emitter offline' }, -> { :aft_emitter_up }
  end

  def red_alert(systems) = puts("RED ALERT: #{systems.join(', ')} offline")

  def scan = circuit(:network).call { raise IOError, 'subspace relay down' }
end

ship = Starship.new
%i[weapons sensors].each { |system| ship.circuit(system) }
2.times do
  ship.scan
rescue IOError => e
  puts "scan failed: #{e.message}"
end
puts ship.circuits_summary.values
puts "shields: #{ship.circuit(:shields).call}"
