# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Execution handles the core circuit breaker logic including call wrapping,
    # state-based request handling, and failure/success tracking.
    module Execution
      extend ActiveSupport::Concern

      # Lazy load async support only when needed
      def self.load_async_support
        require 'async'
        require 'async/task'
      rescue LoadError
        raise LoadError, "The 'async' gem is required for fiber_safe mode. Add `gem 'async'` to your Gemfile."
      end

      def call(&)
        wrap(&)
      end

      def wrap(&block)
        @mutex.with_read_lock do
          case status_name
          when :open
            handle_open_status(&block)
          when :half_open
            handle_half_open_status(&block)
          when :closed
            handle_closed_status(&block)
          end
        end
      end

      private

      def handle_open_status(&)
        if reset_timeout_elapsed?
          @mutex.with_write_lock do
            attempt_recovery if open?
          end
          handle_half_open_status(&)
        else
          reject_call
        end
      end

      def handle_half_open_status(&)
        # Atomically increment and get the new value
        new_attempts = @half_open_attempts.increment

        if new_attempts <= @config[:half_open_calls]
          execute_call(&)
        else
          # This thread lost the race, decrement back and reject
          @half_open_attempts.decrement
          reject_call
        end
      end

      def handle_closed_status(&)
        execute_call(&)
      end

      def execute_call(&block)
        # Use async version if fiber_safe is enabled
        return execute_call_async(&block) if @config[:fiber_safe]

        start_time = monotonic_time

        begin
          # IMPORTANT: We do NOT implement forceful timeouts as they are inherently unsafe
          # The timeout configuration is provided for documentation/intent purposes
          # Users should implement timeouts in their own code using safe mechanisms
          # (e.g., HTTP client timeouts, database statement timeouts, etc.)
          # Log a warning if timeout is configured
          if @config[:timeout] && BreakerMachines.logger && BreakerMachines.config.log_events
            BreakerMachines.logger.warn(
              "[BreakerMachines] Circuit '#{@name}' has timeout configured but " \
              'forceful timeouts are not implemented for safety. ' \
              'Please use timeout mechanisms provided by your libraries ' \
              '(e.g., Net::HTTP read_timeout, ActiveRecord statement_timeout).'
            )
          end

          # Execute normally without forceful timeout
          result = block.call

          record_success(monotonic_time - start_time)
          handle_success
          result
        rescue *@config[:exceptions] => e
          record_failure(monotonic_time - start_time, e)
          handle_failure
          raise unless @config[:fallback]

          invoke_fallback(e)
        end
      end

      def execute_call_async(&)
        # Ensure async is loaded
        Execution.load_async_support unless defined?(::Async)

        start_time = monotonic_time

        begin
          result = if @config[:timeout]
                     # Use safe, cooperative timeout from async gem
                     ::Async::Task.current.with_timeout(@config[:timeout], &)
                   else
                     yield
                   end

          record_success(monotonic_time - start_time)
          handle_success
          result
        rescue ::Async::TimeoutError => e
          # Handle async timeout as a failure
          record_failure(monotonic_time - start_time, e)
          handle_failure
          raise unless @config[:fallback]

          invoke_fallback_async(e)
        rescue *@config[:exceptions] => e
          record_failure(monotonic_time - start_time, e)
          handle_failure
          raise unless @config[:fallback]

          invoke_fallback_async(e)
        end
      end

      def reject_call
        @metrics&.record_rejection(@name)
        invoke_callback(:on_reject)

        raise BreakerMachines::CircuitOpenError.new(@name, @opened_at.value) unless @config[:fallback]

        invoke_fallback(BreakerMachines::CircuitOpenError.new(@name, @opened_at.value))
      end

      def handle_success
        @mutex.with_write_lock do
          if half_open?
            # Check if all allowed half-open calls have succeeded
            # This ensures the circuit can close even if success_threshold > half_open_calls
            successful_attempts = @half_open_successes.increment

            # Fast-close logic: Circuit closes if EITHER:
            # 1. All allowed half-open calls succeeded (conservative approach)
            # 2. Success threshold is reached (aggressive approach for quick recovery)
            # This allows flexible configuration - set success_threshold=1 for fast recovery
            # or success_threshold=half_open_calls for cautious recovery
            if successful_attempts >= @config[:half_open_calls] || success_threshold_reached?
              @half_open_attempts.value = 0
              @half_open_successes.value = 0
              reset
            end
          end
        end
      end

      def handle_failure
        @mutex.with_write_lock do
          if closed? && failure_threshold_exceeded?
            trip
          elsif half_open?
            @half_open_attempts.value = 0
            @half_open_successes.value = 0
            trip
          end
        end
      end

      def failure_threshold_exceeded?
        recent_failures = @storage.failure_count(@name, @config[:failure_window])
        recent_failures >= @config[:failure_threshold]
      end

      def success_threshold_reached?
        recent_successes = @storage.success_count(@name, @config[:failure_window])
        recent_successes >= @config[:success_threshold]
      end

      def record_success(duration)
        @metrics&.record_success(@name, duration)
        @storage&.record_success(@name, duration)
        return unless @storage.respond_to?(:record_event_with_details)

        @storage.record_event_with_details(@name, :success,
                                           duration)
      end

      def record_failure(duration, error = nil)
        @last_failure_at.value = monotonic_time
        @last_error.value = error if error
        @metrics&.record_failure(@name, duration)
        @storage&.record_failure(@name, duration)
        return unless @storage.respond_to?(:record_event_with_details)

        @storage.record_event_with_details(@name, :failure, duration,
                                           error: error)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
