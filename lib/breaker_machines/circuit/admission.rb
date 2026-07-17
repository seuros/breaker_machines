# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Admission reserves calls under short locks and tracks their state generation.
    module Admission
      extend ActiveSupport::Concern

      Call = Data.define(:state, :state_epoch) do
        def closed?
          state == :closed
        end

        def half_open?
          state == :half_open
        end
      end

      private

      def attempt_recovery_if_ready
        return unless open? && reset_timeout_elapsed?

        @mutex.with_write_lock do
          attempt_recovery if open? && reset_timeout_elapsed?
        end
      end

      def admit_call
        @mutex.with_read_lock do
          case status_name
          when :closed
            Call.new(state: :closed, state_epoch: @state_epoch.value)
          when :half_open
            admit_half_open_call
          end
        end
      end

      def admit_half_open_call
        state_epoch = @state_epoch.value
        new_attempts = @half_open_attempts.increment

        return Call.new(state: :half_open, state_epoch:) if new_attempts <= @config[:half_open_calls]

        # This caller lost the race for a probe slot.
        @half_open_attempts.decrement
        nil
      end

      def admission_current?(admission)
        admission.state_epoch == @state_epoch.value
      end

      def handle_success(admission)
        return unless admission.half_open?

        @mutex.with_write_lock do
          return unless admission_current?(admission) && half_open?

          successful_attempts = @half_open_successes.increment
          next unless successful_attempts >= @config[:half_open_calls] || success_threshold_reached?

          @half_open_attempts.value = 0
          @half_open_successes.value = 0
          reset
        end
      end

      def handle_failure(admission)
        @mutex.with_write_lock do
          return unless admission_current?(admission)

          if admission.closed? && closed? && failure_threshold_exceeded?
            trip
          elsif admission.half_open? && half_open?
            @half_open_attempts.value = 0
            @half_open_successes.value = 0
            trip
          end
        end
      end

      def release_abandoned_admission(admission)
        return unless admission.half_open?

        @mutex.with_write_lock do
          next unless admission_current?(admission) && half_open?
          next unless @half_open_attempts.value.positive?

          @half_open_attempts.decrement
        end
      end
    end
  end
end
