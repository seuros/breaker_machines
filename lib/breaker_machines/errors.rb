# frozen_string_literal: true

module BreakerMachines
  # Every error the runtime raises.
  class Error < StandardError; end

  # A circuit refused to admit a call and no fallback replaced it.
  # `refusal` is the core's Symbol; `retry_after` is the Integer nanoseconds
  # until a probe may run, while the circuit is open.
  class CircuitRefusedError < Error
    attr_reader :circuit_name, :refusal, :retry_after

    def initialize(circuit_name, refusal, retry_after = nil, message = nil)
      @circuit_name = circuit_name
      @refusal = refusal
      @retry_after = retry_after
      super(message || "Circuit '#{circuit_name}' refused the call: #{refusal}")
    end
  end

  # Refused because the circuit is open (`:open`) or every half-open probe
  # slot is taken (`:busy`).
  class CircuitOpenError < CircuitRefusedError; end

  # Refused at the concurrency limit (`:full`).
  class CircuitBulkheadError < CircuitRefusedError; end

  # Refused by the runtime before the core was asked: a circuit this one
  # depends on is down. `refusal` is `:dependency`, the runtime's own (not a
  # core refusal); `dependencies` names the circuits that are down, and is
  # empty when only a CircuitGroup member's `guard_with:` refused.
  class CircuitDependencyError < CircuitRefusedError
    attr_reader :dependencies

    def initialize(circuit_name, dependencies)
      @dependencies = dependencies
      reason = dependencies.empty? ? 'its guard refused' : "#{dependencies.join(', ')} down"
      super(circuit_name, :dependency, nil, "Circuit '#{circuit_name}' cannot be called: #{reason}")
    end
  end

  # A call ran past the circuit's `timeout:` (Integer nanoseconds).
  class CircuitTimeoutError < Error
    attr_reader :circuit_name, :timeout

    def initialize(circuit_name, timeout)
      @circuit_name = circuit_name
      @timeout = timeout
      super("Circuit '#{circuit_name}' timed out after #{timeout}ns")
    end
  end

  # A storage backend failed, or held a record that is not a valid value.
  class StorageError < Error; end

  # Every parallel fallback raised; `errors` holds what each raised.
  class ParallelFallbackError < Error
    attr_reader :errors

    def initialize(message, errors)
      @errors = errors
      super(message)
    end
  end
end
