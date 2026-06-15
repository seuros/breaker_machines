# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Methods shared by the in-memory storage backends (Memory and BucketMemory).
    #
    # Status storage, event-detail logging and the relative monotonic clock are
    # identical between the two backends; only the event counting strategy
    # (raw event arrays vs. fixed-size buckets) differs, so those methods stay
    # in each backend.
    module MemorySupport
      def get_status(circuit_name)
        circuit_data = @circuits[circuit_name]
        return nil unless circuit_data

        BreakerMachines::Status.new(
          status: circuit_data[:status],
          opened_at: circuit_data[:opened_at]
        )
      end

      def set_status(circuit_name, status, opened_at = nil)
        @circuits[circuit_name] = {
          status: status,
          opened_at: opened_at,
          updated_at: monotonic_time
        }
      end

      def record_success(circuit_name, duration)
        record_event(circuit_name, :success, duration)
      end

      def record_failure(circuit_name, duration)
        record_event(circuit_name, :failure, duration)
      end

      def success_count(circuit_name, window_seconds)
        count_events(circuit_name, :success, window_seconds)
      end

      def failure_count(circuit_name, window_seconds)
        count_events(circuit_name, :failure, window_seconds)
      end

      def record_event_with_details(circuit_name, type, duration, error: nil, new_state: nil)
        events = @event_logs.compute_if_absent(circuit_name) { Concurrent::Array.new }

        event = {
          type: type,
          timestamp: monotonic_time,
          duration_ms: (duration * 1000).round(2)
        }

        event[:error_class] = error.class.name if error
        event[:error_message] = error.message if error
        event[:new_state] = new_state if new_state

        events << event

        # Keep only the most recent events
        events.shift while events.size > @max_events
      end

      def event_log(circuit_name, limit)
        events = @event_logs[circuit_name]
        return [] unless events

        events.last(limit).map(&:dup)
      end

      private

      def monotonic_time
        # Return time relative to storage creation (matches Rust implementation)
        BreakerMachines.monotonic_time - @start_time
      end
    end
  end
end
