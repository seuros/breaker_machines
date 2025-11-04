# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Native extension storage backend for high-performance event tracking
    #
    # This backend provides identical functionality to Memory storage but with
    # significantly better performance for sliding window calculations. It's
    # particularly beneficial for high-throughput applications where circuit
    # breaker state checks happen on every request.
    #
    # Performance: ~63x faster than Memory storage for sliding window calculations
    #
    # Usage:
    #   BreakerMachines.configure do |config|
    #     config.default_storage = :native
    #   end
    #
    # Fallback: If the native extension isn't available (e.g., on JRuby or if
    # Rust wasn't installed during gem installation), this will raise LoadError.
    # Use Storage::Memory as a fallback in such cases.
    class Native < Base
      def initialize(**options)
        super
        unless defined?(BreakerMachinesNative::Storage)
          raise LoadError, 'Native extension not available. Use Storage::Memory instead.'
        end

        @native = BreakerMachinesNative::Storage.new
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
        @native.record_success(circuit_name.to_s, duration.to_f)
      end

      def record_failure(circuit_name, duration)
        @native.record_failure(circuit_name.to_s, duration.to_f)
      end

      def success_count(circuit_name, window_seconds)
        @native.success_count(circuit_name.to_s, window_seconds.to_f)
      end

      def failure_count(circuit_name, window_seconds)
        @native.failure_count(circuit_name.to_s, window_seconds.to_f)
      end

      def clear(circuit_name)
        @native.clear(circuit_name.to_s)
      end

      def clear_all
        @native.clear_all
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
        @native.event_log(circuit_name.to_s, limit)
      end

      def with_timeout(_timeout_ms)
        # Native operations should be instant
        yield
      end
    end
  end
end
