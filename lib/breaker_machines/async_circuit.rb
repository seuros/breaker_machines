# frozen_string_literal: true

require_relative 'circuit/async_state_management'

module BreakerMachines
  # AsyncCircuit provides a circuit breaker with async-enabled state machine
  # for thread-safe, fiber-safe concurrent operations
  class AsyncCircuit
    include Circuit::AsyncStateManagement
    include Circuit::Configuration
    include Circuit::Execution
    include Circuit::HedgedExecution
    include Circuit::Introspection
    include Circuit::Callbacks

    # Additional async-specific methods
    def call_async(&block)
      require 'async' unless defined?(::Async)

      Async do
        call(&block)
      end
    end

    # Fire state transition events asynchronously
    # @param event_name [Symbol] The event to fire
    # @return [Async::Task] The async task
    def fire_async(event_name)
      require 'async' unless defined?(::Async)

      fire_event_async(event_name)
    end

    # Check circuit health asynchronously
    # Useful for monitoring multiple circuits concurrently
    def health_check_async
      require 'async' unless defined?(::Async)

      Async do
        {
          name: @name,
          status: status_name,
          open: open?,
          stats: stats.to_h,
          can_recover: open? && reset_timeout_elapsed?
        }
      end
    end
  end
end
