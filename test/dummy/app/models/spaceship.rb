# frozen_string_literal: true

class Spaceship
  include BreakerMachines::DSL

  attr_reader :name, :captain_log

  circuit :warp_drive do
    threshold failures: 3, within: 60
    reset_after 30
    timeout 5

    fallback { emergency_propulsion }

    on_open { log_event('WARNING: Warp drive circuit breaker opened!') }
    on_close { log_event('Warp drive systems restored') }
  end

  circuit :fusion_reactor do
    threshold failures: 2, within: 30
    reset_after 45

    fallback { backup_power_supply }

    on_open { log_event('CRITICAL: Fusion reactor offline!') }
    on_half_open { log_event('Attempting reactor restart...') }
  end

  circuit :navigation_computer do
    threshold failures: 5, within: 120
    reset_after 20
    timeout 3

    fallback { manual_navigation }
    handle SpaceflightSystems::NavigationSystemOfflineError
  end

  def initialize(name)
    @name = name
    @captain_log = []
  end

  def engage_warp(destination)
    circuit(:warp_drive).wrap do
      SpaceflightSystems::WarpDrive.engage(destination)
    end
  end

  def power_up_reactor(level = 100)
    circuit(:fusion_reactor).wrap do
      SpaceflightSystems::FusionReactor.ignite(level)
    end
  end

  def calculate_route(coordinates)
    circuit(:navigation_computer).wrap do
      SpaceflightSystems::NavigationComputer.calculate_route(coordinates)
    end
  end

  private

  def emergency_propulsion
    log_event('Engaging emergency thrusters')
    { status: 'emergency_mode', speed: 'impulse_only' }
  end

  def backup_power_supply
    log_event('Switching to auxiliary power')
    { status: 'auxiliary', power_output: 40, temperature: 'stable' }
  end

  def manual_navigation
    log_event('Switching to manual navigation')
    { route: 'manual', distance: 'unknown', eta: 'calculating...' }
  end

  def log_event(message)
    @captain_log << "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
  end
end
