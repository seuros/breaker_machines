# frozen_string_literal: true

require 'zeitwerk'
require 'active_support'
require 'active_support/core_ext'
require 'state_machines'
require_relative 'breaker_machines/errors'
require_relative 'breaker_machines/types'

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect('dsl' => 'DSL')
loader.ignore("#{__dir__}/breaker_machines/errors.rb")
loader.ignore("#{__dir__}/breaker_machines/types.rb")
loader.ignore("#{__dir__}/breaker_machines/console.rb")
loader.ignore("#{__dir__}/breaker_machines/async_support.rb")
loader.ignore("#{__dir__}/breaker_machines/hedged_async_support.rb")
loader.setup

# BreakerMachines provides a thread-safe implementation of the Circuit Breaker pattern
# for Ruby applications, helping to prevent cascading failures in distributed systems.
module BreakerMachines
  class << self
    def loader
      loader
    end
  end

  # Global configuration
  include ActiveSupport::Configurable

  config_accessor :default_storage, default: :bucket_memory
  config_accessor :default_timeout, default: nil
  config_accessor :default_reset_timeout, default: 60.seconds
  config_accessor :default_failure_threshold, default: 5
  config_accessor :log_events, default: true
  config_accessor :fiber_safe, default: false

  class << self
    def configure
      yield config
    end

    def setup_notifications
      return unless config.log_events

      ActiveSupport::Notifications.subscribe(/^breaker_machines\./) do |name, _start, _finish, _id, payload|
        event_type = name.split('.').last
        circuit_name = payload[:circuit]

        case event_type
        when 'opened'
          logger&.warn "[BreakerMachines] Circuit '#{circuit_name}' opened"
        when 'closed'
          logger&.info "[BreakerMachines] Circuit '#{circuit_name}' closed"
        when 'half_opened'
          logger&.info "[BreakerMachines] Circuit '#{circuit_name}' half-opened"
        end
      end
    end

    def logger
      @logger ||= ActiveSupport::Logger.new($stdout)
    end

    attr_writer :logger

    def instrument(event, payload = {})
      return unless config.log_events

      ActiveSupport::Notifications.instrument("breaker_machines.#{event}", payload)
    end

    # Launch the interactive console
    def console
      require_relative 'breaker_machines/console'
      Console.start
    end

    # Get the global registry
    def registry
      Registry.instance
    end

    # Register a circuit with the global registry
    def register(circuit)
      registry.register(circuit)
    end

    # Reset the registry and configurations (useful for testing)
    def reset!
      registry.clear
      config.default_storage = :bucket_memory
      config.default_timeout = nil
      config.default_reset_timeout = 60.seconds
      config.default_failure_threshold = 5
      config.log_events = true
      config.fiber_safe = false
    end

    # Returns the current monotonic time in seconds.
    # Monotonic time is guaranteed to always increase and is not affected
    # by system clock adjustments, making it ideal for measuring durations.
    #
    # @return [Float] current monotonic time in seconds
    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  # Set up notifications on first use
  setup_notifications if config.log_events
end
