# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Backends tried in order: each operation goes to the first that does not
    # raise; a backend that raised is skipped for `cooldown` nanoseconds.
    # When every backend raises, StorageError.
    class FallbackChain
      attr_reader :backends

      def initialize(backends, cooldown: 30_000_000_000, clock: BreakerMachines.method(:monotonic_time))
        raise ArgumentError, 'a fallback chain needs a backend' if backends.empty?

        @backends = backends.dup.freeze
        @cooldown = cooldown
        @clock = clock
        @failed_at = {}
        @mutex = Mutex.new
      end

      def read_status(name) = first { |backend| backend.read_status(name) }
      def write_status(name, record) = first { |backend| backend.write_status(name, record) }
      def record_event(name, event) = first { |backend| backend.record_event(name, event) }
      def event_log(name, limit) = first { |backend| backend.event_log(name, limit) }
      def clear(name) = each_healthy { |backend| backend.clear(name) }
      def clear_all = each_healthy(&:clear_all)

      private

      def first
        errors = []
        healthy.each do |backend|
          return yield(backend)
        rescue StandardError => e
          errors << e
          mark_failed(backend)
        end
        raise StorageError, "every storage backend failed: #{errors.map(&:message).join('; ')}"
      end

      def each_healthy(&)
        healthy.each(&)
        nil
      end

      def healthy
        now = @clock.call
        live = @mutex.synchronize do
          @backends.reject { |backend| (at = @failed_at[backend]) && now - at < @cooldown }
        end
        live.empty? ? @backends : live
      end

      def mark_failed(backend) = @mutex.synchronize { @failed_at[backend] = @clock.call }
    end
  end
end
