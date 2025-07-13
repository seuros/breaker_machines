# frozen_string_literal: true

# This file contains all async-related functionality for fiber-safe mode
# It is only loaded when fiber_safe mode is enabled

require 'async'
require 'async/task'

module BreakerMachines
  # AsyncSupport provides fiber-safe execution capabilities using the async gem
  module AsyncSupport
    extend ActiveSupport::Concern

    # Returns the Async::TimeoutError class if available
    def async_timeout_error_class
      ::Async::TimeoutError
    end

    # Execute a call with async support (fiber-safe mode)
    def execute_call_async(&)
      start_time = BreakerMachines.monotonic_time

      begin
        # Execute with hedged requests if enabled
        result = if @config[:hedged_requests] || @config[:backends]
                   execute_hedged(&)
                 else
                   execute_with_async_timeout(@config[:timeout], &)
                 end

        record_success(BreakerMachines.monotonic_time - start_time)
        handle_success
        result
      rescue StandardError => e
        # Re-raise if it's not an async timeout or configured exception
        raise unless e.is_a?(async_timeout_error_class) || @config[:exceptions].any? { |klass| e.is_a?(klass) }

        record_failure(BreakerMachines.monotonic_time - start_time, e)
        handle_failure
        raise unless @config[:fallback]

        invoke_fallback_with_async(e)
      end
    end

    # Execute a block with optional timeout using Async
    def execute_with_async_timeout(timeout, &)
      if timeout
        # Use safe, cooperative timeout from async gem
        ::Async::Task.current.with_timeout(timeout, &)
      else
        yield
      end
    end

    # Invoke fallback in async context
    def invoke_fallback_with_async(error)
      case @config[:fallback]
      when BreakerMachines::DSL::ParallelFallbackWrapper
        invoke_parallel_fallbacks(@config[:fallback].fallbacks, error)
      when Proc
        result = if @config[:owner]
                   @config[:owner].instance_exec(error, &@config[:fallback])
                 else
                   @config[:fallback].call(error)
                 end

        # If the fallback returns an Async::Task, wait for it
        result.is_a?(::Async::Task) ? result.wait : result
      when Array
        # Try each fallback in order until one succeeds
        last_error = error
        @config[:fallback].each do |fallback|
          return invoke_single_fallback_async(fallback, last_error)
        rescue StandardError => e
          last_error = e
        end
        raise last_error
      else
        # Static values (strings, hashes, etc.) or Symbol fallbacks
        @config[:fallback]
      end
    end

    private

    def invoke_single_fallback_async(fallback, error)
      case fallback
      when Proc
        result = if @config[:owner]
                   @config[:owner].instance_exec(error, &fallback)
                 else
                   fallback.call(error)
                 end

        # If the fallback returns an Async::Task, wait for it
        result.is_a?(::Async::Task) ? result.wait : result
      else
        fallback
      end
    end
  end
end
