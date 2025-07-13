# frozen_string_literal: true

module BreakerMachines
  module DSL
    # DSL builder for configuring circuit breakers with a fluent interface
    class CircuitBuilder
      attr_reader :config

      def initialize
        @config = {
          failure_threshold: 5,
          failure_window: 60.seconds,
          success_threshold: 1,
          timeout: nil,
          reset_timeout: 60.seconds,
          half_open_calls: 1,
          exceptions: [StandardError],
          storage: nil,
          metrics: nil,
          fallback: nil,
          on_open: nil,
          on_close: nil,
          on_half_open: nil,
          on_reject: nil,
          notifications: [],
          fiber_safe: BreakerMachines.config.fiber_safe
        }
      end

      def threshold(failures: nil, failure_rate: nil, minimum_calls: nil, within: 60.seconds, successes: nil)
        if failure_rate
          # Rate-based threshold
          validate_failure_rate!(failure_rate)
          validate_positive_integer!(:minimum_calls, minimum_calls) if minimum_calls

          @config[:failure_rate] = failure_rate
          @config[:minimum_calls] = minimum_calls || 5
          @config[:use_rate_threshold] = true
        elsif failures
          # Absolute count threshold (existing behavior)
          validate_positive_integer!(:failures, failures)
          @config[:failure_threshold] = failures
          @config[:use_rate_threshold] = false
        end

        validate_positive_integer!(:within, within.to_i)
        @config[:failure_window] = within.to_i

        return unless successes

        validate_positive_integer!(:successes, successes)
        @config[:success_threshold] = successes
      end

      def reset_after(duration, jitter: nil)
        validate_positive_integer!(:duration, duration.to_i)
        @config[:reset_timeout] = duration.to_i

        return unless jitter

        validate_jitter!(jitter)
        @config[:reset_timeout_jitter] = jitter
      end

      def timeout(duration)
        validate_non_negative_integer!(:timeout, duration.to_i)
        @config[:timeout] = duration.to_i
      end

      def half_open_requests(count)
        validate_positive_integer!(:half_open_requests, count)
        @config[:half_open_calls] = count
      end

      def storage(backend, **options)
        @config[:storage] = case backend
                            when :memory
                              Storage::Memory.new(**options)
                            when :bucket_memory
                              Storage::BucketMemory.new(**options)
                            when :cache
                              Storage::Cache.new(**options)
                            when :null
                              Storage::Null.new(**options)
                            when :fallback_chain
                              config = options.is_a?(Proc) ? options.call(timeout: 5) : options
                              Storage::FallbackChain.new(config)
                            when Class
                              backend.new(**options)
                            else
                              backend
                            end
      end

      def metrics(recorder = nil, &block)
        @config[:metrics] = recorder || block
      end

      def fallback(value = nil, &block)
        raise ArgumentError, 'Fallback requires either a value or a block' if value.nil? && !block_given?

        fallback_value = block || value

        if @config[:fallback].is_a?(Array)
          @config[:fallback] << fallback_value
        elsif @config[:fallback]
          @config[:fallback] = [@config[:fallback], fallback_value]
        else
          @config[:fallback] = fallback_value
        end
      end

      def on_open(&block)
        @config[:on_open] = block
      end

      def on_close(&block)
        @config[:on_close] = block
      end

      def on_half_open(&block)
        @config[:on_half_open] = block
      end

      def on_reject(&block)
        @config[:on_reject] = block
      end

      # Configure hedged requests
      def hedged(&)
        if block_given?
          hedged_builder = DSL::HedgedBuilder.new(@config)
          hedged_builder.instance_eval(&)
        else
          @config[:hedged_requests] = true
        end
      end

      # Configure multiple backends
      def backends(*backend_list)
        @config[:backends] = backend_list.flatten
      end

      # Configure parallel fallback execution
      def parallel_fallback(fallback_list)
        @config[:fallback] = DSL::ParallelFallbackWrapper.new(fallback_list)
      end

      def notify(service, url = nil, events: %i[open close], **options)
        notification = {
          via: service,
          url: url,
          events: Array(events),
          options: options
        }
        @config[:notifications] << notification
      end

      def handle(*exceptions)
        @config[:exceptions] = exceptions
      end

      def fiber_safe(enabled = true) # rubocop:disable Style/OptionalBooleanParameter
        @config[:fiber_safe] = enabled
      end

      def max_concurrent(limit)
        validate_positive_integer!(:max_concurrent, limit)
        @config[:max_concurrent] = limit
      end

      # Advanced features
      def parallel_calls(count, timeout: nil)
        @config[:parallel_calls] = count
        @config[:parallel_timeout] = timeout
      end

      private

      def validate_positive_integer!(name, value)
        return if value.is_a?(Integer) && value.positive?

        raise BreakerMachines::ConfigurationError,
              "#{name} must be a positive integer, got: #{value.inspect}"
      end

      def validate_non_negative_integer!(name, value)
        return if value.is_a?(Integer) && value >= 0

        raise BreakerMachines::ConfigurationError,
              "#{name} must be a non-negative integer, got: #{value.inspect}"
      end

      def validate_failure_rate!(rate)
        return if rate.is_a?(Numeric) && rate >= 0.0 && rate <= 1.0

        raise BreakerMachines::ConfigurationError,
              "failure_rate must be between 0.0 and 1.0, got: #{rate.inspect}"
      end

      def validate_jitter!(jitter)
        return if jitter.is_a?(Numeric) && jitter >= 0.0 && jitter <= 1.0

        raise BreakerMachines::ConfigurationError,
              "jitter must be between 0.0 and 1.0 (0% to 100%), got: #{jitter.inspect}"
      end
    end
  end
end
