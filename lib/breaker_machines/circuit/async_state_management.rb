# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # AsyncStateManagement provides state machine functionality with async support
    # leveraging state_machines' async: true parameter for thread-safe operations
    module AsyncStateManagement
      extend ActiveSupport::Concern

      included do
        # Enable async mode for thread-safe state transitions
        # This automatically provides:
        # - Mutex-protected state reads/writes
        # - Fiber-safe execution
        # - Concurrent transition handling
        state_machine :status, initial: :closed, async: true do
          event :attempt_recovery do
            transition open: :half_open
          end

          event :reset do
            transition %i[open half_open] => :closed
            transition closed: :closed
          end

          instance_eval(&StateMachineDefinition::COMMON)
        end

        # Additional async event methods are automatically generated:
        # - trip_async! - Returns Async::Task
        # - attempt_recovery_async! - Returns Async::Task
        # - reset_async! - Returns Async::Task
        # - fire_event_async(:event_name) - Generic async event firing
      end
    end
  end
end
