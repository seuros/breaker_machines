# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Shared state machine definition for circuit breakers.
    #
    # The trip/force_open/force_close/hard_reset events and the transition
    # callbacks are identical across the sync, async, and coordinated state
    # management modules. Only the +attempt_recovery+ and +reset+ events differ
    # (coordinated circuits add guard conditions), so those stay in each module
    # while everything common is spliced in via instance_eval(&COMMON).
    module StateMachineDefinition
      COMMON = proc do
        event :trip do
          transition closed: :open
          transition half_open: :open
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
  end
end
