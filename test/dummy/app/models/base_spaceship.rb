# frozen_string_literal: true

# Base spaceship class with common circuits
class BaseSpaceship
  include BreakerMachines::DSL

  circuit :engine do
    threshold failures: 3, within: 60
    reset_after 30
    fallback { 'Emergency power' }
  end

  circuit :shields do
    threshold failures: 5, within: 120
    reset_after 45
  end

  def start_engine
    circuit(:engine).wrap { 'Engine started' }
  end

  def raise_shields
    circuit(:shields).wrap { 'Shields up' }
  end
end
