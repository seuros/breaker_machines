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

  # Raised when a circuit cannot be called due to unmet dependencies
  class CircuitDependencyError < CircuitOpenError
    def initialize(circuit_name, message = nil)
      @circuit_name = circuit_name
      @opened_at = nil
      super_message = message || "Circuit '#{circuit_name}' cannot be called: dependencies not met"
      Error.instance_method(:initialize).bind(self).call(super_message)
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

  # Raised when storage backend operation times out
  class StorageTimeoutError < StorageError
    attr_reader :timeout_ms

    def initialize(message, timeout_ms = nil)
      @timeout_ms = timeout_ms
      super(message)
    end
  end

  # Raised when circuit rejects call due to bulkhead limit
  class CircuitBulkheadError < Error
    attr_reader :circuit_name, :max_concurrent

    def initialize(circuit_name, max_concurrent)
      @circuit_name = circuit_name
      @max_concurrent = max_concurrent
      super("Circuit '#{circuit_name}' rejected call: max concurrent limit of #{max_concurrent} reached")
    end
  end
end
