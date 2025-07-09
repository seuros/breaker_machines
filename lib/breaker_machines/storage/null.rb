# frozen_string_literal: true

module BreakerMachines
  module Storage
    # A no-op storage backend for minimal overhead
    # Use this when you don't need event logging or metrics
    class Null < Base
      def record_success(_circuit_name, _duration = nil)
        # No-op
      end

      def record_failure(_circuit_name, _duration = nil)
        # No-op
      end

      def success_count(_circuit_name, _window = nil)
        0
      end

      def failure_count(_circuit_name, _window = nil)
        0
      end

      def get_status(_circuit_name)
        nil
      end

      def set_status(_circuit_name, _status, _opened_at = nil)
        # No-op
      end

      def clear(_circuit_name)
        # No-op
      end

      def event_log(_circuit_name, _limit = 20)
        []
      end

      def record_event_with_details(_circuit_name, _event_type, _duration, _metadata = {})
        # No-op
      end

      def clear_all
        # No-op
      end

      def with_timeout(_timeout_ms)
        # Null storage always succeeds instantly - perfect for fail-open scenarios
        yield
      end
    end
  end
end
