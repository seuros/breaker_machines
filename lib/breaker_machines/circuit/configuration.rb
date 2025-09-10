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
          fiber_safe: BreakerMachines.config.fiber_safe,
          # Rate-based threshold options
          use_rate_threshold: false,
          failure_rate: nil,
          minimum_calls: 5,
          # Bulkheading options
          max_concurrent: nil,
          # Hedged request options
          hedged_requests: false,
          hedging_delay: 50, # milliseconds
          max_hedged_requests: 2,
          backends: nil
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
          # Allow for custom storage class names or instances
          if BreakerMachines.config.default_storage.respond_to?(:new)
            BreakerMachines.config.default_storage.new
          else
            BreakerMachines.config.default_storage
          end
        end
      end
    end
  end
end
