# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # StateCallbacks provides the common callback methods shared by all state management modules
    module StateCallbacks
      extend ActiveSupport::Concern

      private

      def on_circuit_open
        @state_epoch.increment
        @opened_at.value = BreakerMachines.monotonic_time
        persist_status(:open, @opened_at.value)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :open)
        end
        invoke_callback(:on_open)
        BreakerMachines.instrument('opened', circuit: @name)
      end

      def on_circuit_close
        @state_epoch.increment
        @opened_at.value = nil
        @last_error.value = nil
        @last_failure_at.value = nil
        persist_status(:closed)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :closed)
        end
        invoke_callback(:on_close)
        BreakerMachines.instrument('closed', circuit: @name)
      end

      def on_circuit_half_open
        @state_epoch.increment
        @half_open_attempts.value = 0
        @half_open_successes.value = 0
        persist_status(:half_open, @opened_at.value)
        if @storage.respond_to?(:record_event_with_details)
          @storage.record_event_with_details(@name, :state_change, 0,
                                             new_state: :half_open)
        end
        invoke_callback(:on_half_open)
        BreakerMachines.instrument('half_opened', circuit: @name)
      end

      def reset_timeout_elapsed?
        return false unless @opened_at.value

        timeout_with_jitter = if (jitter_factor = @config[:reset_timeout_jitter]) && jitter_factor.positive?
                                ChronoMachines.jitter(@config[:reset_timeout], factor: jitter_factor)
                              else
                                @config[:reset_timeout]
                              end

        BreakerMachines.monotonic_time - @opened_at.value >= timeout_with_jitter
      end

    end
  end
end
