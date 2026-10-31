# frozen_string_literal: true

require 'test_helper'

class DeadlineAdmissionTest < ActiveSupport::TestCase
  setup do
    @clock = DeadlineMachines::TestClock.new
    DeadlineMachines.clock = @clock
    @circuit = BreakerMachines::Circuit.new('payments', failure_threshold: 2, reset_timeout: 30)
  end

  teardown do
    DeadlineMachines.clock = nil
  end

  test 'an abandoned caller does not count toward the failure threshold' do
    5.times do
      DeadlineMachines.with_deadline(5) do |deadline|
        deadline.cancel('client hung up')
        assert_raises(DeadlineMachines::Cancelled) do
          @circuit.wrap { raise IOError, 'slow' }
        end
      end
    end

    assert_predicate @circuit, :closed?
    assert_equal 0, @circuit.stats.failure_count
  end

  test 'an inner scope expiring is a real timeout and counts as a failure' do
    DeadlineMachines.with_deadline(60) do
      2.times do
        assert_raises(DeadlineMachines::Exceeded) do
          @circuit.wrap do
            DeadlineMachines.with_deadline(1) do
              @clock.advance(2)
              DeadlineMachines.check!
            end
          end
        end
      end
    end

    assert_predicate @circuit, :open?
  end
end
