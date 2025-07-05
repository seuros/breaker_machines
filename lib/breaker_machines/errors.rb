# frozen_string_literal: true

module BreakerMachines
  class Error < StandardError; end

  # Raised when attempting to use a circuit that is in the open state
  class CircuitOpenError < Error
    attr_reader :circuit_name, :opened_at

    def initialize(circuit_name, opened_at = nil)
      @circuit_name = circuit_name
      @opened_at = opened_at
      super("Circuit '#{circuit_name}' is open")
    end
  end

  # Raised when a circuit-protected call exceeds the configured timeout
  class CircuitTimeoutError < Error
    attr_reader :circuit_name, :timeout

    def initialize(circuit_name, timeout)
      @circuit_name = circuit_name
      @timeout = timeout
      super("Circuit '#{circuit_name}' timed out after #{timeout}s")
    end
  end

  class ConfigurationError < Error; end
  class StorageError < Error; end
end
