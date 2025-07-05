# frozen_string_literal: true

# Explorer ship with completely different circuits
class ExplorerShip < BaseSpaceship
  circuit :scanner do
    threshold failures: 1, within: 10
    reset_after 5
    timeout 2
  end

  circuit :probe_launcher do
    threshold failures: 3, within: 60
    reset_after 30
  end

  def scan_planet
    circuit(:scanner).wrap { 'Planet scanned' }
  end

  def launch_probe
    circuit(:probe_launcher).wrap { 'Probe launched' }
  end
end
