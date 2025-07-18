# frozen_string_literal: true

require 'concurrent'
require 'timeout'

module BreakerMachines
  class Circuit
    # HedgedExecution provides hedged request functionality for circuit breakers
    # Hedged requests improve latency by sending duplicate requests to multiple backends
    # and returning the first successful response
    module HedgedExecution
      extend ActiveSupport::Concern

      # Execute a hedged request pattern
      def execute_hedged(&)
        return execute_single_hedged(&) unless @config[:backends]&.any?

        execute_multi_backend_hedged
      end

      private

      # Execute hedged request with a single backend (original block)
      def execute_single_hedged(&block)
        return yield unless hedged_requests_enabled?

        max_requests = @config[:max_hedged_requests] || 2
        delay_ms = @config[:hedging_delay] || 50

        if @config[:fiber_safe]
          execute_hedged_async(Array.new(max_requests) { block }, delay_ms)
        else
          execute_hedged_sync(Array.new(max_requests) { block }, delay_ms)
        end
      end

      # Execute hedged requests across multiple backends
      def execute_multi_backend_hedged
        backends = @config[:backends]
        return backends.first.call if backends.size == 1

        if @config[:fiber_safe]
          execute_hedged_async(backends, @config[:hedging_delay] || 0)
        else
          execute_hedged_sync(backends, @config[:hedging_delay] || 0)
        end
      end

      # Synchronous hedged execution using threads
      def execute_hedged_sync(callables, delay_ms)
        result_queue = Queue.new
        error_queue = Queue.new
        threads = []
        cancelled = Concurrent::AtomicBoolean.new(false)

        callables.each_with_index do |callable, index|
          # Add delay for hedge requests (not the first one)
          sleep(delay_ms / 1000.0) if index.positive? && delay_ms.positive?

          # Skip if already got a result
          break if cancelled.value

          threads << Thread.new do
            unless cancelled.value
              begin
                result = callable.call
                result_queue << result unless cancelled.value
                cancelled.value = true
              rescue StandardError => e
                error_queue << e unless cancelled.value
              end
            end
          end
        end

        # Wait for first result or all errors
        begin
          Timeout.timeout(@config[:timeout] || 30) do
            # Check for successful result
            loop do
              unless result_queue.empty?
                result = result_queue.pop
                cancelled.value = true
                return result
              end

              # Check if all requests failed
              raise error_queue.pop if error_queue.size >= callables.size

              # Small sleep to prevent busy waiting
              sleep 0.001
            end
          end
        ensure
          # Cancel remaining threads
          cancelled.value = true
          threads.each(&:kill)
        end
      end

      # Async hedged execution (requires async support)
      def execute_hedged_async(callables, delay_ms)
        # This will be implemented when async support is loaded
        # For now, fall back to sync implementation
        return execute_hedged_sync(callables, delay_ms) unless respond_to?(:execute_hedged_with_async)

        execute_hedged_with_async(callables, delay_ms)
      end

      def hedged_requests_enabled?
        @config[:hedged_requests] == true
      end
    end
  end
end
