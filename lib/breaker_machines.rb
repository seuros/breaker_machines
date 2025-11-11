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
loader.ignore("#{__dir__}/breaker_machines/circuit/async_state_management.rb")
loader.ignore("#{__dir__}/breaker_machines/native_speedup.rb")
loader.ignore("#{__dir__}/breaker_machines/native_extension.rb")
loader.setup

# BreakerMachines provides a thread-safe implementation of the Circuit Breaker pattern
# for Ruby applications, helping to prevent cascading failures in distributed systems.
module BreakerMachines
  # Global configuration class for BreakerMachines
  class Configuration
    attr_accessor :default_storage,
                  :default_timeout,
                  :default_reset_timeout,
                  :default_failure_threshold,
                  :log_events,
                  :fiber_safe

    def initialize
      @default_storage = :bucket_memory
      @default_timeout = nil
      @default_reset_timeout = 60.seconds
      @default_failure_threshold = 5
      @log_events = true
      @fiber_safe = false
    end
  end

  class << self
    def loader
      loader
    end

    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Delegate config attributes to config object for backward compatibility
    def default_storage
      config.default_storage
    end

    def default_storage=(value)
      config.default_storage = value
    end

    def default_timeout
      config.default_timeout
    end

    def default_timeout=(value)
      config.default_timeout = value
    end

    def default_reset_timeout
      config.default_reset_timeout
    end

    def default_reset_timeout=(value)
      config.default_reset_timeout = value
    end

    def default_failure_threshold
      config.default_failure_threshold
    end

    def default_failure_threshold=(value)
      config.default_failure_threshold = value
    end

    def log_events
      config.log_events
    end

    def log_events=(value)
      config.log_events = value
    end

    def fiber_safe
      config.fiber_safe
    end

    def fiber_safe=(value)
      config.fiber_safe = value
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

    # Centralized logging helper
    # @param level [Symbol] log level (:debug, :info, :warn, :error)
    # @param message [String] message to log
    def log(level, message)
      return unless config.log_events && logger

      logger.public_send(level, "[BreakerMachines] #{message}")
    end

    def instrument(event, payload = {})
      return unless config.log_events

      ActiveSupport::Notifications.instrument("breaker_machines.#{event}", payload)
    end

    # Check if native extension is available
    # @return [Boolean] true if native extension loaded successfully
    def native_available?
      @native_available || false
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

# Load optional native speedup after core is loaded
# Automatically loads if available, gracefully falls back to pure Ruby if not
begin
  require_relative 'breaker_machines/native_speedup'
rescue LoadError
  # Native extension not available, using pure Ruby backend
  # This is expected on JRuby or when Cargo is not available
end
