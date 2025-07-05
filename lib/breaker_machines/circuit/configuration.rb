# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Configuration manages circuit initialization and default settings,
    # including thresholds, timeouts, storage backends, and callbacks.
    module Configuration
      extend ActiveSupport::Concern

      included do
        attr_reader :name, :config, :opened_at
      end

      def initialize(name, options = {})
        @name = name
        @config = default_config.merge(options)
        # Always use a storage backend for proper sliding window implementation
        # Use global default storage if not specified
        @storage = @config[:storage] || create_default_storage
        @metrics = @config[:metrics]
        @opened_at = Concurrent::AtomicReference.new(nil)
        @half_open_attempts = Concurrent::AtomicFixnum.new(0)
        @half_open_successes = Concurrent::AtomicFixnum.new(0)
        @mutex = Concurrent::ReentrantReadWriteLock.new
        @last_failure_at = Concurrent::AtomicReference.new(nil)
        @last_error = Concurrent::AtomicReference.new(nil)

        super() # Initialize state machine
        restore_status_from_storage if @storage

        # Register with global registry
        BreakerMachines::Registry.instance.register(self)
      end

      private

      def default_config
        {
          failure_threshold: 5,
          failure_window: 60, # seconds
          success_threshold: 1,
          timeout: nil,
          reset_timeout: 60, # seconds
          reset_timeout_jitter: 0.25, # +/- 25% by default
          half_open_calls: 1,
          storage: nil, # Will default to Memory storage if nil
          metrics: nil,
          fallback: nil,
          on_open: nil,
          on_close: nil,
          on_half_open: nil,
          on_reject: nil,
          exceptions: [StandardError],
          fiber_safe: BreakerMachines.config.fiber_safe
        }
      end

      def create_default_storage
        case BreakerMachines.config.default_storage
        when :memory
          BreakerMachines::Storage::Memory.new
        when :bucket_memory
          BreakerMachines::Storage::BucketMemory.new
        when :null
          BreakerMachines::Storage::Null.new
        else
          # Allow for custom storage class names
          BreakerMachines.config.default_storage.new
        end
      end
    end
  end
end
