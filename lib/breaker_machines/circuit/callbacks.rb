# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Callbacks handles the invocation of user-defined callbacks and fallback mechanisms
    # when circuit state changes occur or calls are rejected.
    module Callbacks
      extend ActiveSupport::Concern

      private

      def invoke_callback(callback_name)
        callback = @config[callback_name]
        return unless callback

        return unless callback.is_a?(Proc)

        if @config[:owner]
          @config[:owner].instance_exec(&callback)
        else
          callback.call
        end
      end

      def invoke_fallback(error)
        case @config[:fallback]
        when BreakerMachines::DSL::ParallelFallbackWrapper
          invoke_parallel_fallbacks(@config[:fallback].fallbacks, error)
        when Proc
          if @config[:owner]
            @config[:owner].instance_exec(error, &@config[:fallback])
          else
            @config[:fallback].call(error)
          end
        when Array
          # Try each fallback in order until one succeeds
          last_error = error
          @config[:fallback].each do |fallback|
            return invoke_single_fallback(fallback, last_error)
          rescue StandardError => e
            last_error = e
          end
          raise last_error
        else
          # Static values (strings, hashes, etc.) or Symbol fallbacks
          @config[:fallback]
        end
      end

      def invoke_single_fallback(fallback, error)
        case fallback
        when Proc
          if @config[:owner]
            @config[:owner].instance_exec(error, &fallback)
          else
            fallback.call(error)
          end
        else
          fallback
        end
      end

      def invoke_parallel_fallbacks(fallbacks, error)
        return fallbacks.first if fallbacks.size == 1

        if @config[:fiber_safe] && respond_to?(:execute_parallel_fallbacks_async)
          execute_parallel_fallbacks_async(fallbacks)
        else
          execute_parallel_fallbacks_sync(fallbacks, error)
        end
      end

      def execute_parallel_fallbacks_sync(fallbacks, error)
        result_queue = Queue.new
        error_queue = Queue.new
        threads = fallbacks.map do |fallback|
          Thread.new do
            result = if fallback.is_a?(Proc)
                       if fallback.arity == 1
                         fallback.call(error)
                       else
                         fallback.call
                       end
                     else
                       fallback
                     end
            result_queue << result
          rescue StandardError => e
            error_queue << e
          end
        end

        # Wait for first successful result
        begin
          Timeout.timeout(5) do # reasonable timeout for fallbacks
            loop do
              return result_queue.pop unless result_queue.empty?

              raise error_queue.pop if error_queue.size >= fallbacks.size

              sleep 0.001
            end
          end
        ensure
          threads.each(&:kill)
        end
      end
    end
  end
end
