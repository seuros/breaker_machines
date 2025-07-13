# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Manages the health state of a single storage backend using a state machine.
    class BackendState
      attr_reader :name, :failure_count, :last_failure_at
      attr_accessor :health

      def initialize(name, threshold:, timeout:)
        @name = name
        @threshold = threshold
        @timeout = timeout
        @failure_count = 0
        @last_failure_at = nil
        @health = :healthy
      end

      state_machine :health, initial: :healthy do
        event :trip do
          transition :healthy => :unhealthy, if: :threshold_reached?
        end

        event :recover do
          transition :unhealthy => :healthy
        end

        event :reset do
          transition all => :healthy
        end

        before_transition to: :unhealthy do |backend, _transition|
          backend.instance_variable_set(:@unhealthy_until, BreakerMachines.monotonic_time + backend.instance_variable_get(:@timeout))
        end

        after_transition to: :healthy do |backend, _transition|
          backend.instance_variable_set(:@failure_count, 0)
          backend.instance_variable_set(:@last_failure_at, nil)
          backend.instance_variable_set(:@unhealthy_until, nil)
        end
      end

      def record_failure
        @failure_count += 1
        @last_failure_at = BreakerMachines.monotonic_time
        trip
      end

      def threshold_reached?
        @failure_count >= @threshold
      end

      def unhealthy_due_to_timeout?
        return false unless unhealthy?

        unhealthy_until = instance_variable_get(:@unhealthy_until)
        return false unless unhealthy_until

        if BreakerMachines.monotonic_time > unhealthy_until
          recover
          false
        else
          true
        end
      end
    end
  end
end
