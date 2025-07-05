# frozen_string_literal: true

require 'concurrent/map'
require 'concurrent/array'

module BreakerMachines
  module Storage
    # Efficient bucket-based memory storage implementation
    # Uses fixed-size circular buffers for constant-time event counting
    class BucketMemory < Base
      BUCKET_SIZE = 1 # 1 second per bucket

      def initialize(**options)
        super
        @circuits = Concurrent::Map.new
        @circuit_buckets = Concurrent::Map.new
        @event_logs = Concurrent::Map.new
        @bucket_count = options[:bucket_count] || 300 # Default 5 minutes
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
        @circuit_buckets.delete(circuit_name)
        @event_logs.delete(circuit_name)
      end

      def clear_all
        @circuits.clear
        @circuit_buckets.clear
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

      def record_event(circuit_name, type, _duration)
        buckets = @circuit_buckets.compute_if_absent(circuit_name) do
          {
            successes: Concurrent::Array.new(@bucket_count) { Concurrent::AtomicFixnum.new(0) },
            failures: Concurrent::Array.new(@bucket_count) { Concurrent::AtomicFixnum.new(0) },
            last_bucket_time: Concurrent::AtomicReference.new(current_bucket_time)
          }
        end

        current_time = current_bucket_time
        rotate_buckets_if_needed(buckets, current_time)

        bucket_index = current_time % @bucket_count
        counter_array = type == :success ? buckets[:successes] : buckets[:failures]
        counter_array[bucket_index].increment
      end

      def count_events(circuit_name, type, window_seconds)
        buckets = @circuit_buckets[circuit_name]
        return 0 unless buckets

        current_time = current_bucket_time
        rotate_buckets_if_needed(buckets, current_time)

        # Calculate how many buckets to count
        buckets_to_count = [window_seconds / BUCKET_SIZE, @bucket_count].min.to_i

        counter_array = type == :success ? buckets[:successes] : buckets[:failures]
        total = 0

        buckets_to_count.times do |i|
          bucket_index = (current_time - i) % @bucket_count
          total += counter_array[bucket_index].value
        end

        total
      end

      def rotate_buckets_if_needed(buckets, current_time)
        last_time = buckets[:last_bucket_time].value

        return if current_time == last_time

        # Only one thread should rotate buckets
        return unless buckets[:last_bucket_time].compare_and_set(last_time, current_time)

        # Clear buckets that are now outdated
        time_diff = current_time - last_time
        buckets_to_clear = [time_diff, @bucket_count].min

        buckets_to_clear.times do |i|
          # Clear the bucket that will be reused
          bucket_index = (last_time + i + 1) % @bucket_count
          buckets[:successes][bucket_index].value = 0
          buckets[:failures][bucket_index].value = 0
        end
      end

      def current_bucket_time
        (monotonic_time / BUCKET_SIZE).to_i
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
