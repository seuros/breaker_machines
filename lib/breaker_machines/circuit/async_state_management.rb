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
          event :trip do
            transition closed: :open
            transition half_open: :open
          end

          event :attempt_recovery do
            transition open: :half_open
          end

          event :reset do
            transition %i[open half_open] => :closed
            transition closed: :closed
          end

          event :force_open do
            transition any => :open
          end

          event :force_close do
            transition any => :closed
          end

          event :hard_reset do
            transition any => :closed
          end

          before_transition on: :hard_reset do |circuit|
            circuit.storage&.clear(circuit.name)
            circuit.half_open_attempts.value = 0
            circuit.half_open_successes.value = 0
          end

          # Async-safe callbacks using modern API
          after_transition to: :open do |circuit|
            circuit.send(:on_circuit_open)
          end

          after_transition to: :closed do |circuit|
            circuit.send(:on_circuit_close)
          end

          after_transition from: :open, to: :half_open do |circuit|
            circuit.send(:on_circuit_half_open)
          end
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
