# frozen_string_literal: true

require 'logger'

module BreakerMachines
  # Process-wide runtime settings. They are runtime defaults only: nothing
  # here reaches the core.
  #
  # - `log_events` instrument and log transitions (true).
  # - `fiber_safe` the default for Circuit's `fiber_safe:` (false).
  # - `default_storage` the default for Circuit's `storage:` (nil: alone).
  # - `logger` where `log` writes (a Logger on $stdout).
  class Configuration
    attr_accessor :log_events, :fiber_safe, :default_storage
    attr_writer :logger

    def initialize
      @log_events = true
      @fiber_safe = false
      @default_storage = nil
      @logger = nil
    end

    def logger = (@logger ||= Logger.new($stdout))
  end

  class << self
    def config = (@config ||= Configuration.new)

    def configure = yield(config)

    def logger = config.logger

    # Restore every setting and empty the registry (for tests).
    def reset!
      @config = Configuration.new
      registry.clear
    end

    # Wall-clock Integer nanoseconds since the Unix epoch, the clock circuits
    # sharing a storage read: monotonic clocks of two processes do not agree.
    def wall_time = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)

    # Publish `breaker_machines.<event>` through ActiveSupport::Notifications
    # when it is loaded and events are logged; a no-op otherwise.
    def instrument(event, payload = {})
      return unless config.log_events && defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument("breaker_machines.#{event}", payload)
    end

    # Log transitions published by `instrument` to `logger`.
    def setup_notifications
      return unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.subscribe(/\Abreaker_machines\./) do |name, _start, _finish, _id, payload|
        event = name.delete_prefix('breaker_machines.')
        level = event == 'opened' ? :warn : :info
        log(level, "Circuit '#{payload[:circuit]}' #{event}") if %w[opened closed half_opened].include?(event)
      end
    end

    def log(level, message)
      return unless config.log_events

      logger.public_send(level, "[BreakerMachines] #{message}")
    end

    # The interactive console over the registry.
    def console(input: $stdin, output: $stdout)
      Console.new(input:, output:).run
    end
  end
end
