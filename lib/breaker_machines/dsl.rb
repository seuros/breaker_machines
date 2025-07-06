# frozen_string_literal: true

module BreakerMachines
  # DSL module for adding circuit breakers to classes
  #
  # This module uses WeakRef to track instances that include the DSL.
  # Why? In long-running applications (web servers, background workers),
  # objects that include this DSL may be created and destroyed frequently.
  # Without WeakRef, the registry would hold strong references to these
  # objects, preventing garbage collection and causing memory leaks.
  #
  # Example scenario: A Rails controller that includes BreakerMachines::DSL
  # is instantiated for each request. Without WeakRef, every controller
  # instance would be kept in memory forever.
  module DSL
    extend ActiveSupport::Concern

    # Track instances for each class that includes DSL
    # Using WeakRef to allow garbage collection
    @instance_registries = Concurrent::Map.new

    class_methods do
      # Get or create instance registry for this class
      def instance_registry
        # Access the module-level registry
        registry = BreakerMachines::DSL.instance_variable_get(:@instance_registries)
        registry.compute_if_absent(self) { Concurrent::Array.new }
      end

      # Clean up dead references in the registry
      def cleanup_instance_registry
        registry = instance_registry
        # Concurrent::Array supports delete_if
        registry.delete_if do |weak_ref|
          weak_ref.__getobj__
          false
        rescue WeakRef::RefError
          true
        end
      end

      def circuit(name, &block)
        @circuits ||= {}

        if block_given?
          builder = CircuitBuilder.new
          builder.instance_eval(&block)
          @circuits[name] = builder.config
        end

        @circuits[name]
      end

      def circuits
        # Start with parent circuits if available
        base_circuits = if superclass.respond_to?(:circuits)
                          superclass.circuits.deep_dup
                        else
                          {}
                        end

        # Merge with our own circuits
        if @circuits
          base_circuits.merge(@circuits)
        else
          base_circuits
        end
      end

      # Get circuit definitions without sensitive data
      def circuit_definitions
        circuits.transform_values { |config| config.except(:owner, :storage, :metrics) }
      end

      # Reset all circuits for all instances of this class
      def reset_all_circuits
        cleanup_instance_registry # Clean up dead refs first

        instance_registry.each do |weak_ref|
          instance = weak_ref.__getobj__
          circuit_instances = instance.instance_variable_get(:@circuit_instances)
          circuit_instances&.each_value(&:reset)
        rescue WeakRef::RefError
          # Instance was garbage collected, skip it
        end
      end

      # Get aggregated stats for all circuits of this class
      def circuit_stats
        stats = Hash.new { |h, k| h[k] = { total: 0, by_state: {} } }
        cleanup_instance_registry # Clean up dead refs first

        instance_registry.each do |weak_ref|
          instance = weak_ref.__getobj__
          circuit_instances = instance.instance_variable_get(:@circuit_instances)
          next unless circuit_instances

          circuit_instances.each do |name, circuit|
            stats[name][:total] += 1
            state = circuit.status_name
            stats[name][:by_state][state] ||= 0
            stats[name][:by_state][state] += 1
          end
        rescue WeakRef::RefError
          # Instance was garbage collected, skip it
        end

        stats
      end
    end

    # Use included callback to add instance tracking
    def self.included(base)
      super

      # Hook into new to register instances
      base.singleton_class.prepend(Module.new do
        def new(...)
          instance = super
          instance_registry << WeakRef.new(instance)
          instance
        end
      end)
    end

    def circuit(name)
      self.class.circuits[name] ||= {}
      @circuit_instances ||= {}
      @circuit_instances[name] ||= Circuit.new(name, self.class.circuits[name].merge(owner: self))
    end

    # Get all circuit instances for this object
    def circuit_instances
      @circuit_instances || {}
    end

    # Get summary of all circuits for this instance
    def circuits_summary
      circuit_instances.transform_values(&:summary)
    end

    # Get detailed information for all circuits
    def circuits_report
      circuit_instances.transform_values(&:to_h)
    end

    # Reset all circuits for this instance
    def reset_all_circuits
      circuit_instances.each_value(&:reset)
    end

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

      def storage(backend, **)
        @config[:storage] = case backend
                            when :memory
                              Storage::Memory.new(**)
                            when :bucket_memory
                              Storage::BucketMemory.new(**)
                            when :cache
                              Storage::Cache.new(**)
                            when :redis
                              Storage::Redis.new(**)
                            when Class
                              backend.new(**)
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
          hedged_builder = HedgedBuilder.new(@config)
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
        @config[:fallback] = ParallelFallbackWrapper.new(fallback_list)
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

      def fiber_safe(enabled: true)
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

    # Builder for hedged request configuration
    class HedgedBuilder
      def initialize(config)
        @config = config
        @config[:hedged_requests] = true
      end

      def delay(milliseconds)
        @config[:hedging_delay] = milliseconds
      end

      def max_requests(count)
        @config[:max_hedged_requests] = count
      end
    end

    # Wrapper to indicate parallel execution for fallbacks
    class ParallelFallbackWrapper
      attr_reader :fallbacks

      def initialize(fallbacks)
        @fallbacks = fallbacks
      end

      def call(error)
        # This will be handled by the circuit's fallback mechanism
        # to execute fallbacks in parallel
        raise NotImplementedError, 'ParallelFallbackWrapper should be handled by Circuit'
      end
    end
  end
end
