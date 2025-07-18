# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # CoordinatedStateManagement extends the base state machine with coordinated guards
    # that allow circuits to make transitions based on the state of other circuits.
    module CoordinatedStateManagement
      extend ActiveSupport::Concern

      included do
        # Override the state machine to add coordinated guards
        state_machine :status, initial: :closed do
          event :trip do
            transition closed: :open
            transition half_open: :open
          end

          event :attempt_recovery do
            transition open: :half_open,
                       if: ->(circuit) { circuit.recovery_allowed? }
          end

          event :reset do
            transition %i[open half_open] => :closed,
                       if: ->(circuit) { circuit.reset_allowed? }
            transition closed: :closed
          end

          event :force_open do
            transition any => :open
          end

          event :force_close do
            transition any => :closed
          end

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
      end

      # Check if this circuit can attempt recovery
      # For cascading circuits, this checks if dependent circuits allow it
      def recovery_allowed?
        return true unless respond_to?(:dependent_circuits) && dependent_circuits.any?

        # Don't attempt recovery if any critical dependencies are still down
        !has_critical_dependencies_down?
      end

      # Check if this circuit can reset to closed
      # For cascading circuits, ensures dependencies are healthy
      def reset_allowed?
        return true unless respond_to?(:dependent_circuits) && dependent_circuits.any?

        # Only reset if all dependencies are in acceptable states
        all_dependencies_healthy?
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

      protected

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

      private

      # Check if any critical dependencies are down
      def has_critical_dependencies_down?
        return false unless respond_to?(:dependent_circuits)

        dependent_circuits.any? do |circuit_name|
          circuit = find_dependent_circuit(circuit_name)
          circuit&.open?
        end
      end

      # Check if all dependencies are in healthy states
      def all_dependencies_healthy?
        return true unless respond_to?(:dependent_circuits)

        dependent_circuits.all? do |circuit_name|
          circuit = find_dependent_circuit(circuit_name)
          circuit.nil? || circuit.closed? || circuit.half_open?
        end
      end

      # Find a dependent circuit by name
      def find_dependent_circuit(circuit_name)
        # First try registry
        circuit = BreakerMachines.registry.find(circuit_name)

        # If not found and we have an owner, try to get it from the owner
        if !circuit && @config[:owner]
          owner = @config[:owner]
          owner = owner.__getobj__ if owner.is_a?(WeakRef)
          circuit = owner.circuit(circuit_name) if owner.respond_to?(:circuit)
        end

        circuit
      end
    end
  end
end
