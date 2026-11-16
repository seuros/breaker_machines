# frozen_string_literal: true

module BreakerMachines
  # A Circuit for fiber-based concurrency: fiber-safe by default, with calls,
  # forced transitions and health checks run as tasks of the `async` gem
  # (required on first use; add it to your Gemfile).
  class AsyncCircuit < Circuit
    def initialize(name, policy, fiber_safe: true, **runtime)
      super
    end

    # `call` as an Async task; `.wait` for the result.
    def call_async(&)
      require 'async'
      Async { call(&) }
    end

    # Run `:force_open`, `:force_close` or `:reset` as an Async task.
    def fire_async(event)
      raise ArgumentError, "unknown event #{event.inspect}" unless %i[force_open force_close reset].include?(event)

      require 'async'
      Async { public_send(event) }
    end

    # The circuit's health as an Async task answering a Hash.
    def health_check_async
      require 'async'
      Async do
        { name:, state:, open: open?, stats: stats.to_h, can_recover: open? && retry_after.zero? }
      end
    end
  end
end
