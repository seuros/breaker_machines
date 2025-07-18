# frozen_string_literal: true

require_relative 'circuit/coordinated_state_management'

module BreakerMachines
  # CoordinatedCircuit is a base class for circuits that need coordinated state management.
  # It replaces the standard StateManagement module with CoordinatedStateManagement
  # to enable state transitions based on other circuits' states.
  class CoordinatedCircuit
    include Circuit::CoordinatedStateManagement
    include Circuit::Configuration
    include Circuit::Execution
    include Circuit::HedgedExecution
    include Circuit::Introspection
    include Circuit::Callbacks
  end
end
