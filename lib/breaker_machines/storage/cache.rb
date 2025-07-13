# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Storage adapter for ActiveSupport::Cache
    # Works with any Rails cache store (Redis, Memcached, Memory, etc.)
    class Cache < Base
      def initialize(cache_store: Rails.cache, **options)
        super(**options)
        @cache = cache_store
        @prefix = options[:prefix] || 'breaker_machines'
        @expires_in = options[:expires_in] || 300 # 5 minutes default
      end

      def get_status(circuit_name)
        data = @cache.read(status_key(circuit_name))
        return nil unless data

        {
          status: data[:status].to_sym,
          opened_at: data[:opened_at]
        }
      end

      def set_status(circuit_name, status, opened_at = nil)
        @cache.write(
          status_key(circuit_name),
          {
            status: status,
            opened_at: opened_at,
            updated_at: monotonic_time
          },
          expires_in: @expires_in
        )
      end

      def record_success(circuit_name, _duration)
        increment_counter(success_key(circuit_name))
      end

      def record_failure(circuit_name, _duration)
        increment_counter(failure_key(circuit_name))
      end

      def success_count(circuit_name, window_seconds)
        get_window_count(success_key(circuit_name), window_seconds)
      end

      def failure_count(circuit_name, window_seconds)
        get_window_count(failure_key(circuit_name), window_seconds)
      end

      def clear(circuit_name)
        @cache.delete(status_key(circuit_name))
        @cache.delete(success_key(circuit_name))
        @cache.delete(failure_key(circuit_name))
        @cache.delete(events_key(circuit_name))
      end

      def clear_all
        # Clear all circuit data by pattern if cache supports it
        if @cache.respond_to?(:delete_matched)
          @cache.delete_matched("#{@prefix}:*")
        else
          # Fallback: can't efficiently clear all without pattern support
          BreakerMachines.logger&.warn(
            "[BreakerMachines] Cache store doesn't support delete_matched. " \
            'Individual circuit data must be cleared manually.'
          )
        end
      end

      def record_event_with_details(circuit_name, type, duration, error: nil, new_state: nil)
        events = @cache.fetch(events_key(circuit_name)) { [] }

        event = {
          type: type,
          timestamp: monotonic_time,
          duration_ms: (duration * 1000).round(2)
        }

        event[:error_class] = error.class.name if error
        event[:error_message] = error.message if error
        event[:new_state] = new_state if new_state

        events << event
        events.shift while events.size > (@max_events || 100)

        @cache.write(events_key(circuit_name), events, expires_in: @expires_in)
      end

      def event_log(circuit_name, limit)
        events = @cache.read(events_key(circuit_name)) || []
        events.last(limit)
      end

      def with_timeout(_timeout_ms)
        # Rails cache operations should rely on their own underlying timeouts
        # Using Ruby's Timeout.timeout is dangerous and can cause deadlocks
        # For Redis cache stores, configure connect_timeout and read_timeout instead
        yield
      end

      private

      def increment_counter(key)
        # Use increment if available, otherwise fetch-and-update
        if @cache.respond_to?(:increment)
          @cache.increment(key, 1, expires_in: @expires_in)
        else
          # Fallback for caches without atomic increment
          current = @cache.fetch(key) { {} }
          current[current_bucket] = (current[current_bucket] || 0) + 1
          prune_old_buckets(current)
          @cache.write(key, current, expires_in: @expires_in)
        end
      end

      def get_window_count(key, window_seconds)
        if @cache.respond_to?(:increment)
          # For simple counter-based caches, we can't get windowed counts
          # Would need to implement bucketing similar to fallback
          @cache.read(key) || 0
        else
          # Bucket-based counting for accurate windows
          buckets = @cache.read(key) || {}
          current_time = current_bucket

          total = 0
          window_seconds.times do |i|
            bucket_key = current_time - i
            total += buckets[bucket_key] || 0
          end

          total
        end
      end

      def prune_old_buckets(buckets)
        cutoff = current_bucket - 300 # Keep 5 minutes of data
        buckets.delete_if { |time, _| time < cutoff }
      end

      def current_bucket
        Time.now.to_i
      end

      def status_key(circuit_name)
        "#{@prefix}:#{circuit_name}:status"
      end

      def success_key(circuit_name)
        "#{@prefix}:#{circuit_name}:successes"
      end

      def failure_key(circuit_name)
        "#{@prefix}:#{circuit_name}:failures"
      end

      def events_key(circuit_name)
        "#{@prefix}:#{circuit_name}:events"
      end

      def monotonic_time
        BreakerMachines.monotonic_time
      end
    end
  end
end
