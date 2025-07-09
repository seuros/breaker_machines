# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Abstract base class for storage backends
    class Base
      def initialize(**options)
        @options = options
      end

      # Status management
      def get_status(circuit_name)
        raise NotImplementedError
      end

      def set_status(circuit_name, status, opened_at = nil)
        raise NotImplementedError
      end

      # Metrics tracking
      def record_success(circuit_name, duration)
        raise NotImplementedError
      end

      def record_failure(circuit_name, duration)
        raise NotImplementedError
      end

      def success_count(circuit_name, window_seconds)
        raise NotImplementedError
      end

      def failure_count(circuit_name, window_seconds)
        raise NotImplementedError
      end

      # Cleanup
      def clear(circuit_name)
        raise NotImplementedError
      end

      def clear_all
        raise NotImplementedError
      end

      # Timeout handling - each backend must implement its own timeout strategy
      def with_timeout(timeout_ms)
        raise NotImplementedError, "#{self.class} must implement #with_timeout to handle #{timeout_ms}ms timeouts"
      end
    end
  end
end
