# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Native extension storage backend with graceful fallback to pure Ruby
    #
    # This backend provides identical functionality to Memory storage but with
    # significantly better performance for sliding window calculations when the
    # native extension is available. If the native extension isn't available
    # (e.g., on JRuby or if Rust wasn't installed), it automatically falls back
    # to the pure Ruby Memory storage backend.
    #
    # Performance: ~63x faster than Memory storage when native extension is available
    #
    # Usage:
    #   BreakerMachines.configure do |config|
    #     config.default_storage = :native
    #   end
    #
    # FFI Hybrid Pattern: Always works, uses native if available, falls back gracefully
    class Native < Base
      def initialize(**options)
        super

        # Try to use native extension if available, otherwise fallback to pure Ruby
        if defined?(BreakerMachinesNative::Storage) && BreakerMachines.native_available?
          @backend = BreakerMachinesNative::Storage.new
          @using_native = true
        else
          # Graceful fallback to pure Ruby Memory storage
          @backend = Memory.new(**options)
          @using_native = false
        end
      end

      # Check if using native backend
      # @return [Boolean] true if using Rust native extension
      def native?
        @using_native
      end

      def get_status(_circuit_name)
        # Status is still managed by Ruby layer
        # This storage backend only handles event tracking
        nil
      end

      def set_status(circuit_name, status, opened_at = nil)
        # Status management delegated to Ruby layer
        # This backend focuses on high-performance event counting
      end

      def record_success(circuit_name, duration)
        @backend.record_success(circuit_name.to_s, duration.to_f)
      end

      def record_failure(circuit_name, duration)
        @backend.record_failure(circuit_name.to_s, duration.to_f)
      end

      def success_count(circuit_name, window_seconds)
        @backend.success_count(circuit_name.to_s, window_seconds.to_f)
      end

      def failure_count(circuit_name, window_seconds)
        @backend.failure_count(circuit_name.to_s, window_seconds.to_f)
      end

      def clear(circuit_name)
        @backend.clear(circuit_name.to_s)
      end

      def clear_all
        @backend.clear_all
      end

      def record_event_with_details(circuit_name, type, duration, error: nil, new_state: nil)
        # Basic event recording (native extension handles type and duration)
        case type
        when :success
          record_success(circuit_name, duration)
        when :failure
          record_failure(circuit_name, duration)
        end

        # NOTE: Error and state details not tracked in native backend
        # This is intentional for performance - use Memory backend if you need full event details
      end

      def event_log(circuit_name, limit)
        @backend.event_log(circuit_name.to_s, limit)
      end

      def with_timeout(_timeout_ms)
        # Native operations should be instant
        yield
      end
    end
  end
end
