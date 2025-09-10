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
          owner = resolve_owner
          if owner
            owner.instance_exec(&callback)
          else
            # Owner has been garbage collected, execute callback without context
            callback.call
          end
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
            owner = resolve_owner
            if owner
              owner.instance_exec(error, &@config[:fallback])
            else
              # Owner has been garbage collected, execute fallback without context
              @config[:fallback].call(error)
            end
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
            owner = resolve_owner
            if owner
              owner.instance_exec(error, &fallback)
            else
              fallback.call(error)
            end
          else
            fallback.call(error)
          end
        else
          fallback
        end
      end

      # Safely resolve owner from WeakRef if applicable
      def resolve_owner
        owner = @config[:owner]
        return owner unless owner.is_a?(WeakRef)

        begin
          owner.__getobj__
        rescue WeakRef::RefError
          # Owner has been garbage collected
          nil
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

        threads.each(&:join)

        if result_queue.empty?
          errors = []
          errors << error_queue.pop until error_queue.empty?
          raise BreakerMachines::ParallelFallbackError.new('All parallel fallbacks failed', errors)
        else
          result_queue.pop
        end
      end
    end
  end
end
