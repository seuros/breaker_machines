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
        # Counter resolution in seconds. Each bucket is its own cache entry, so
        # stores that keep expired entries around (Solid Cache) want coarser buckets.
        @bucket_seconds = Integer(options[:bucket_seconds] || 1)
        raise ArgumentError, 'bucket_seconds must be positive' unless @bucket_seconds.positive?

        @warned_windows = Concurrent::Set.new
      end

      def get_status(circuit_name)
        data = @cache.read(status_key(circuit_name))
        return nil unless data

        BreakerMachines::Status.new(
          status: data[:status].to_sym,
          opened_at: data[:opened_at]
        )
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
        return unless @cache.respond_to?(:increment)

        keys = [success_key(circuit_name), failure_key(circuit_name)].flat_map do |key|
          bucket_keys(key, bucket_count(@expires_in) + 1)
        end
        delete_counters(keys)
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
          # Expiry counts from the first increment, so a bucket must outlive
          # the retention period by its own length.
          @cache.increment("#{key}:#{current_bucket}", 1, expires_in: @expires_in + @bucket_seconds)
        else
          # Fallback for caches without atomic increment
          current = @cache.fetch(key) { {} }
          current[current_bucket] = (current[current_bucket] || 0) + 1
          prune_old_buckets(current)
          @cache.write(key, current, expires_in: @expires_in)
        end
      end

      def get_window_count(key, window_seconds)
        warn_window_exceeds_retention(window_seconds)
        count = bucket_count([window_seconds, @expires_in].min)

        if @cache.respond_to?(:increment)
          read_counters(bucket_keys(key, count)).sum(&:to_i)
        else
          buckets = @cache.read(key) || {}
          now = current_bucket
          count.times.sum { |offset| buckets[now - offset] || 0 }
        end
      end

      # Counters live for expires_in, so a longer window silently undercounts.
      def warn_window_exceeds_retention(window_seconds)
        return if window_seconds <= @expires_in
        return unless @warned_windows.add?(window_seconds)

        BreakerMachines.logger&.warn(
          "[BreakerMachines] Cache storage keeps counts for #{@expires_in}s, so a #{window_seconds}s " \
          "window only sees the last #{@expires_in}s. Set expires_in to at least the window."
        )
      end

      # read_multi is a single round trip; stores without it read each bucket.
      def read_counters(keys)
        return @cache.read_multi(*keys, raw: true).values if @cache.respond_to?(:read_multi)

        keys.filter_map { |key| @cache.read(key) }
      end

      def delete_counters(keys)
        return @cache.delete_multi(keys) if @cache.respond_to?(:delete_multi)

        keys.each { |key| @cache.delete(key) }
      end

      def bucket_count(seconds)
        (seconds.to_f / @bucket_seconds).ceil
      end

      def bucket_keys(key, count)
        now = current_bucket
        Array.new(count) { |offset| "#{key}:#{now - offset}" }
      end

      def prune_old_buckets(buckets)
        cutoff = current_bucket - bucket_count(@expires_in)
        buckets.delete_if { |bucket, _| bucket < cutoff }
      end

      def current_bucket
        Time.now.to_i / @bucket_seconds
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
