# frozen_string_literal: true

require 'concurrent/map'
require 'concurrent/array'

module BreakerMachines
  module Storage
    # High-performance in-memory storage backend with thread-safe operations
    class Memory < Base
      def initialize(**options)
        super
        @circuits = Concurrent::Map.new
        @events = Concurrent::Map.new
        @event_logs = Concurrent::Map.new
        @max_events = options[:max_events] || 100
      end

      def get_status(circuit_name)
        circuit_data = @circuits[circuit_name]
        return nil unless circuit_data

        {
          status: circuit_data[:status],
          opened_at: circuit_data[:opened_at]
        }
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

      def clear(circuit_name)
        @circuits.delete(circuit_name)
        @events.delete(circuit_name)
        @event_logs.delete(circuit_name)
      end

      def clear_all
        @circuits.clear
        @events.clear
        @event_logs.clear
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

      def record_event(circuit_name, type, duration)
        # Initialize if needed
        @events.compute_if_absent(circuit_name) { Concurrent::Array.new }

        # Get the array and add event
        events = @events[circuit_name]
        current_time = monotonic_time

        # Add new event
        events << {
          type: type,
          duration: duration,
          timestamp: current_time
        }

        # Clean old events periodically (every 100 events)
        return unless events.size > 100

        cutoff_time = current_time - 300 # Keep 5 minutes of history
        events.delete_if { |e| e[:timestamp] < cutoff_time }
      end

      def count_events(circuit_name, type, window_seconds)
        events = @events[circuit_name]
        return 0 unless events

        cutoff_time = monotonic_time - window_seconds
        events.count { |e| e[:type] == type && e[:timestamp] >= cutoff_time }
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
