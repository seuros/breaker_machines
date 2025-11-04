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
                       if: lambda(&:recovery_allowed?)
          end

          event :reset do
            transition %i[open half_open] => :closed,
                       if: lambda(&:reset_allowed?)
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
