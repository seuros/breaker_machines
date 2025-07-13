# frozen_string_literal: true

module BreakerMachines
  # Represents the status of a circuit from storage
  # @return [Symbol] status - the circuit status (:open, :closed, :half_open)
  # @return [Float, nil] opened_at - the monotonic time when the circuit was opened
  Status = Data.define(:status, :opened_at)

  # Represents statistical information about a circuit
  Stats = Data.define(
    :state,
    :failure_count,
    :success_count,
    :last_failure_at,
    :opened_at,
    :half_open_attempts,
    :half_open_successes
  )

  # Represents information about the last error that occurred
  # @return [String] error_class - the error class name
  # @return [String] message - the error message
  # @return [Float, nil] occurred_at - the monotonic time when the error occurred
  ErrorInfo = Data.define(:error_class, :message, :occurred_at)

  # Represents cascade information for cascading circuits
  CascadeInfo = Data.define(
    :dependent_circuits,
    :emergency_protocol,
    :cascade_triggered_at,
    :dependent_status
  )

  # Represents an event in the circuit's event log
  # @return [Symbol] type - the event type (:success, :failure, :state_change)
  # @return [Float] timestamp - the monotonic timestamp
  # @return [Float] duration - the duration in milliseconds
  # @return [String, nil] error - the error message if applicable
  # @return [Symbol, nil] new_state - the new state if this was a state change
  Event = Data.define(:type, :timestamp, :duration, :error, :new_state)
end
