# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Execution handles the core circuit breaker logic including call wrapping,
    # state-based request handling, and failure/success tracking.
    module Execution
      extend ActiveSupport::Concern

      # Lazy load async support only when needed
      def self.load_async_support
        require 'breaker_machines/async_support'
        require 'breaker_machines/hedged_async_support'
        Circuit.include(BreakerMachines::AsyncSupport)
        Circuit.include(BreakerMachines::HedgedAsyncSupport)
      rescue LoadError => e
        if e.message.include?('async')
          raise LoadError, "The 'async' gem is required for fiber_safe mode. Add `gem 'async'` to your Gemfile."
        end

        raise
      end

      def call(&)
        wrap(&)
      end

      def wrap(&)
        execute_with_state_check(&)
      end

      private

      def execute_with_state_check(&)
        attempt_recovery_if_ready

        # Apply bulkheading first, outside of any locks
        acquired = false
        if @semaphore
          acquired = @semaphore.try_acquire
          return reject_call_bulkhead unless acquired
        end

        begin
          admission = admit_call
          unless admission
            # An open-circuit fallback is user code and may yield. It must not
            # retain a bulkhead permit or circuit lock while it runs.
            @semaphore&.release if acquired
            acquired = false
            return reject_call
          end

          execute_call(admission, &)
        ensure
          @semaphore&.release if @semaphore && acquired
        end
      end

      def execute_call(admission, &)
        # Use async version if fiber_safe is enabled
        if @config[:fiber_safe]
          # Ensure async is loaded and included
          Execution.load_async_support unless respond_to?(:execute_call_async)
          return execute_call_async(admission, &)
        end

        execute_call_sync(admission, &)
      end

      def execute_call_sync(admission, &)
        completed = false
        start_time = BreakerMachines.monotonic_time

        begin
          result = execute_sync_operation(&)
          complete_call_success(admission, start_time)
          completed = true
          result
        rescue *@config[:exceptions] => e
          complete_call_failure(admission, start_time, e)
          completed = true
          raise unless @config[:fallback]

          invoke_fallback(e)
        ensure
          release_abandoned_admission(admission) unless completed
        end
      end

      def execute_sync_operation(&)
        warn_about_sync_timeout
        return execute_hedged(&) if @config[:hedged_requests] || @config[:backends]

        yield
      end

      def warn_about_sync_timeout
        return unless @config[:timeout] && BreakerMachines.logger && BreakerMachines.config.log_events

        # Forceful Ruby timeouts can interrupt code while it holds resources.
        BreakerMachines.logger.warn(
          "[BreakerMachines] Circuit '#{@name}' has timeout configured but " \
          'forceful timeouts are not implemented for safety. ' \
          'Please use timeout mechanisms provided by your libraries ' \
          '(e.g., Net::HTTP read_timeout, ActiveRecord statement_timeout).'
        )
      end

      def complete_call_success(admission, start_time)
        record_success(BreakerMachines.monotonic_time - start_time)
        handle_success(admission)
      end

      def complete_call_failure(admission, start_time, error)
        record_failure(BreakerMachines.monotonic_time - start_time, error)
        handle_failure(admission)
      end

      def reject_call
        @metrics&.record_rejection(@name)
        invoke_callback(:on_reject)

        raise BreakerMachines::CircuitOpenError.new(@name, @opened_at.value) unless @config[:fallback]

        invoke_fallback(BreakerMachines::CircuitOpenError.new(@name, @opened_at.value))
      end

      def reject_call_bulkhead
        @metrics&.record_rejection(@name)
        invoke_callback(:on_reject)

        error = BreakerMachines::CircuitBulkheadError.new(@name, @config[:max_concurrent])
        raise error unless @config[:fallback]

        invoke_fallback(error)
      end

      def failure_threshold_exceeded?
        if @config[:use_rate_threshold]
          # Rate-based threshold
          window = @config[:failure_window]
          failures = @storage.failure_count(@name, window)
          successes = @storage.success_count(@name, window)
          total_calls = failures + successes

          # Check minimum calls requirement
          return false if total_calls < @config[:minimum_calls]

          # Calculate failure rate
          failure_rate = failures.to_f / total_calls
          failure_rate >= @config[:failure_rate]
        else
          # Absolute count threshold (existing behavior)
          recent_failures = @storage.failure_count(@name, @config[:failure_window])
          recent_failures >= @config[:failure_threshold]
        end
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
        @last_failure_at.value = BreakerMachines.monotonic_time
        @last_error.value = error if error
        @metrics&.record_failure(@name, duration)
        @storage&.record_failure(@name, duration)
        return unless @storage.respond_to?(:record_event_with_details)

        @storage.record_event_with_details(@name, :failure, duration,
                                           error: error)
      end
    end
  end
end
