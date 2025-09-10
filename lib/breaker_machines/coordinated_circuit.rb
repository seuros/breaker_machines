# frozen_string_literal: true

module BreakerMachines
  # CoordinatedCircuit is a base class for circuits that need coordinated state management.
  # It replaces the standard StateManagement module with CoordinatedStateManagement
  # to enable state transitions based on other circuits' states.
  class CoordinatedCircuit < Circuit
    include Circuit::CoordinatedStateManagement
  end
end
