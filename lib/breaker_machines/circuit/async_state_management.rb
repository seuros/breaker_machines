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

      private

      def on_circuit_open
        @opened_at.value = BreakerMachines.monotonic_time
        @storage&.set_status(@name, :open, @opened_at.value)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :open)
        end
        invoke_callback(:on_open)
        BreakerMachines.instrument('opened', circuit: @name)
      end

      def on_circuit_close
        @opened_at.value = nil
        @last_error.value = nil
        @last_failure_at.value = nil
        @storage&.set_status(@name, :closed)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :closed)
        end
        invoke_callback(:on_close)
        BreakerMachines.instrument('closed', circuit: @name)
      end

      def on_circuit_half_open
        @half_open_attempts.value = 0
        @half_open_successes.value = 0
        @storage&.set_status(@name, :half_open)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :half_open)
        end
        invoke_callback(:on_half_open)
        BreakerMachines.instrument('half_opened', circuit: @name)
      end

      def restore_status_from_storage
        stored_status = @storage.get_status(@name)
        return unless stored_status

        self.status = stored_status.status.to_s
        @opened_at.value = stored_status.opened_at if stored_status.opened_at
      end

      def reset_timeout_elapsed?
        return false unless @opened_at.value

        # Add jitter to prevent thundering herd
        jitter_factor = @config[:reset_timeout_jitter] || 0.25
        # Calculate random jitter between -jitter_factor and +jitter_factor
        jitter_multiplier = 1.0 + (((rand * 2) - 1) * jitter_factor)
        timeout_with_jitter = @config[:reset_timeout] * jitter_multiplier

        BreakerMachines.monotonic_time - @opened_at.value >= timeout_with_jitter
      end
    end
  end
end
