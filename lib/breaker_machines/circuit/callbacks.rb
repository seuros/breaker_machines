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

      # Async versions for fiber_safe mode
      def invoke_callback_async(callback_name)
        callback = @config[callback_name]
        return unless callback
        return unless callback.is_a?(Proc)

        result = if @config[:owner]
                   @config[:owner].instance_exec(&callback)
                 else
                   callback.call
                 end

        # If the callback returns an Async::Task, wait for it
        if defined?(::Async::Task) && result.is_a?(::Async::Task)
          result.wait
        else
          result
        end
      end

      def invoke_fallback_async(error)
        case @config[:fallback]
        when Proc
          result = if @config[:owner]
                     @config[:owner].instance_exec(error, &@config[:fallback])
                   else
                     @config[:fallback].call(error)
                   end

          # If the fallback returns an Async::Task, wait for it
          if defined?(::Async::Task) && result.is_a?(::Async::Task)
            result.wait
          else
            result
          end
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

      def invoke_single_fallback_async(fallback, error)
        case fallback
        when Proc
          result = if @config[:owner]
                     @config[:owner].instance_exec(error, &fallback)
                   else
                     fallback.call(error)
                   end

          # If the fallback returns an Async::Task, wait for it
          if defined?(::Async::Task) && result.is_a?(::Async::Task)
            result.wait
          else
            result
          end
        else
          fallback
        end
      end
    end
  end
end
