# frozen_string_literal: true

class BaseShip
  include BreakerMachines::DSL

  attr_reader :name, :registry_number

  def initialize(name, registry_number)
    @name = name
    @registry_number = registry_number
    @captain_log = []
  end

  # All ships have basic systems
  circuit :life_support do
    threshold failures: 2, within: 60
    reset_after 30
    timeout 5

    fallback { activate_emergency_life_support }

    on_open { log_event('CRITICAL: Life support circuit breaker opened!') }
    on_close { log_event('Life support systems restored') }
  end

  circuit :navigation do
    threshold failures: 5, within: 120
    reset_after 45
    timeout 3

    fallback { engage_manual_navigation }

    on_open { log_event('Navigation systems offline') }
  end

  circuit :communications do
    threshold failures: 3, within: 90
    reset_after 20

    fallback { use_emergency_beacon }
  end

  def activate_life_support
    circuit(:life_support).wrap do
      'Life support active at 100%'
    end
  end

  def calculate_course(destination)
    circuit(:navigation).wrap do
      "Course plotted to #{destination}"
    end
  end

  def send_message(message)
    circuit(:communications).wrap do
      "Message sent: #{message}"
    end
  end

  protected

  def log_event(message)
    @captain_log << "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
  end

  def activate_emergency_life_support
    log_event('Emergency life support activated')
    'Emergency oxygen reserves online'
  end

  def engage_manual_navigation
    log_event('Switching to manual navigation')
    'Manual navigation engaged'
  end

  def use_emergency_beacon
    log_event('Emergency beacon activated')
    'SOS beacon transmitting'
  end
end
