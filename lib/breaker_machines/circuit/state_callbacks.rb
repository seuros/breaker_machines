# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # StateCallbacks provides the common callback methods shared by all state management modules
    module StateCallbacks
      extend ActiveSupport::Concern

      private

      def on_circuit_open
        @opened_at.value = BreakerMachines.monotonic_time
        @storage&.set_status(@name, :open, @opened_at.value)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :open)
        end
        invoke_callback(:on_open)
        BreakerMachines.instrument('opened', circuit: @name)
      end

      def on_circuit_close
        @opened_at.value = nil
        @last_error.value = nil
        @last_failure_at.value = nil
        @storage&.set_status(@name, :closed)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :closed)
        end
        invoke_callback(:on_close)
        BreakerMachines.instrument('closed', circuit: @name)
      end

      def on_circuit_half_open
        @half_open_attempts.value = 0
        @half_open_successes.value = 0
        @storage&.set_status(@name, :half_open)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :half_open)
        end
        invoke_callback(:on_half_open)
        BreakerMachines.instrument('half_opened', circuit: @name)
      end

      def reset_timeout_elapsed?
        return false unless @opened_at.value

        # Add jitter to prevent thundering herd using ChronoMachines
        # This matches the Rust implementation which uses chrono-machines for jitter
        timeout_with_jitter = if (jitter_factor = @config[:reset_timeout_jitter]) && jitter_factor.positive?
                                calculate_timeout_with_jitter(@config[:reset_timeout], jitter_factor)
                              else
                                @config[:reset_timeout]
                              end

        BreakerMachines.monotonic_time - @opened_at.value >= timeout_with_jitter
      end

      # Calculate timeout with jitter using ChronoMachines algorithm
      # Matches the Rust implementation: timeout * (1 - jitter + rand * jitter)
      def calculate_timeout_with_jitter(base_timeout, jitter_factor)
        # Use full jitter strategy from ChronoMachines
        # Formula: base * (1 - jitter + rand * jitter)
        # This gives values in range [base * (1-jitter), base]
        normalized_jitter = [jitter_factor.to_f, 1.0].min
        base_timeout * (1.0 - normalized_jitter + (rand * normalized_jitter))
      end
    end
  end
end
