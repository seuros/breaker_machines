# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # StateManagement provides the state machine functionality for circuit breakers,
    # managing transitions between closed, open, and half-open states.
    module StateManagement
      extend ActiveSupport::Concern

      included do
        state_machine :status, initial: :closed do
          event :attempt_recovery do
            transition open: :half_open
          end

          event :reset do
            transition %i[open half_open] => :closed
            transition closed: :closed
          end

          instance_eval(&StateMachineDefinition::COMMON)
        end
      end
    end
  end
end
