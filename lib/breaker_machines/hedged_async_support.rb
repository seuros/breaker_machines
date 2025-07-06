# frozen_string_literal: true

# This file contains async support for hedged execution
# It is only loaded when fiber_safe mode is enabled

require 'async'
require 'async/task'
require 'async/condition'
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
    # Uses Async::Condition to signal the winner instead of an Async::Channel.
    # @param callables [Array<Proc>] Tasks to race
    # @param delay_ms [Integer] Delay in milliseconds between task starts
    # @return [Object] First successful result
    # @raise [Exception] The first exception received
    def race_tasks(callables, delay_ms: 0)
      Async do |parent|
        mutex     = Mutex.new
        condition = Async::Condition.new
        winner    = nil
        exception = nil

        tasks = callables.map.with_index do |callable, idx|
          parent.async do |task|
            # stagger hedged attempts
            task.sleep(delay_ms / 1000.0) if idx.positive? && delay_ms.positive?

            begin
              res = callable.call
              mutex.synchronize do
                next if winner || exception

                winner = res
                condition.signal
              end
            rescue StandardError => e
              mutex.synchronize do
                next if winner || exception

                exception = e
                condition.signal
              end
            end
          end
        end

        # block until first signal
        condition.wait

        # tear down
        tasks.each(&:stop)

        # propagate
        raise(exception) if exception

        winner
      end.wait
    end
  end
end
