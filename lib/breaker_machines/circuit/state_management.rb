# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # StateManagement provides the state machine functionality for circuit breakers,
    # managing transitions between closed, open, and half-open states.
    module StateManagement
      extend ActiveSupport::Concern

      included do
        state_machine :status, initial: :closed do
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
    end
  end
end
