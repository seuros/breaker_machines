# frozen_string_literal: true

# Test cargo ship inherits base circuits and adds cargo systems
class TestCargoShip < BaseSpaceship
  circuit :cargo_bay do
    threshold failures: 10, within: 300
    reset_after 120
  end

  # Override engine with different config
  circuit :engine do
    threshold failures: 5, within: 120 # More tolerant for cargo ships
    reset_after 60
    fallback { 'Auxiliary thrusters' }
  end

  def load_cargo
    circuit(:cargo_bay).wrap { 'Cargo loaded' }
  end
end
