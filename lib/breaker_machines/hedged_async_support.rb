# frozen_string_literal: true

# This file contains async support for hedged execution
# It is only loaded when fiber_safe mode is enabled
# Requires async gem ~> 2.31.0 for Promise and modern API features

require 'async'
require 'async/task'
require 'async/promise'
require 'async/barrier'
require 'concurrent'

module BreakerMachines
  # AsyncSupport for HedgedExecution
  module HedgedAsyncSupport
    # Execute hedged requests with configurable delay between attempts
    # @param callables [Array<Proc>] Array of callables to execute
    # @param delay_ms [Integer] Milliseconds to wait before starting hedged requests
    # @return [Object] Result from the first successful callable
    # @raise [StandardError] If all callables fail
    def execute_hedged_with_async(callables, delay_ms)
      race_tasks(callables, delay_ms: delay_ms)
    end

    # Execute parallel fallbacks without delay
    # @param fallbacks [Array<Proc,Object>] Array of fallback values or callables
    # @return [Object] Result from the first successful fallback
    # @raise [StandardError] If all fallbacks fail
    def execute_parallel_fallbacks_async(fallbacks)
      # Normalize fallbacks to callables
      callables = fallbacks.map do |fallback|
        case fallback
        when Proc
          # Handle procs with different arities
          -> { fallback.arity == 1 ? fallback.call(nil) : fallback.call }
        else
          # Wrap static values in callables
          -> { fallback }
        end
      end

      race_tasks(callables, delay_ms: 0)
    end

    private

    # Race callables; return first result or raise if it was an Exception
    # Uses modern Async::Promise and Async::Barrier for cleaner synchronization
    # @param callables [Array<Proc>] Tasks to race
    # @param delay_ms [Integer] Delay in milliseconds between task starts
    # @return [Object] First successful result
    # @raise [Exception] The first exception received
    def race_tasks(callables, delay_ms: 0)
      promise = Async::Promise.new
      barrier = Async::Barrier.new

      begin
        result = Async do
          callables.each_with_index do |callable, idx|
            barrier.async do
              # stagger hedged attempts
              sleep(delay_ms / 1000.0) if idx.positive? && delay_ms.positive?

              begin
                result = callable.call
                # Try to resolve the promise with this result
                # Only the first resolution will succeed
                promise.resolve(result) unless promise.resolved?
              rescue StandardError => e
                # Only set exception if no result has been resolved yet
                promise.resolve(e) unless promise.resolved?
              end
            end
          end

          # Wait for the first resolution (either success or exception)
          promise.wait
        end.wait

        # If result is an exception, raise it; otherwise return the result
        result.is_a?(StandardError) ? raise(result) : result
      ensure
        # Ensure all tasks are stopped
        barrier&.stop
      end
    end
  end
end
