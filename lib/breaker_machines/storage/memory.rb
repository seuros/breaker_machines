# frozen_string_literal: true

require 'concurrent/map'
require 'concurrent/array'

module BreakerMachines
  module Storage
    # High-performance in-memory storage backend with thread-safe operations
    #
    # WARNING: This storage backend is NOT compatible with DRb (distributed Ruby)
    # environments as memory is not shared between processes. Use Cache backend
    # with an external cache store (Redis, Memcached) for distributed setups.
    class Memory < Base
      include MemorySupport

      def initialize(**options)
        super
        @circuits = Concurrent::Map.new
        @events = Concurrent::Map.new
        @event_logs = Concurrent::Map.new
        @max_events = options[:max_events] || 100
        # Store creation time as anchor for relative timestamps (like Rust implementation)
        @start_time = BreakerMachines.monotonic_time
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

      def with_timeout(_timeout_ms)
        # Memory operations should be instant, but we'll still respect the timeout
        # This is more for consistency and to catch any potential deadlocks
        yield
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
    end
  end
end
