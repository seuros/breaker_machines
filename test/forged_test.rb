# frozen_string_literal: true

require_relative 'test_helper'

class ForgedTest < Minitest::Test
  include BreakerHelpers

  def test_a_value_forged_past_initialize_never_reaches_the_core
    recovery = B::Recovery.new(at(1), 0.0, 1, 1)
    policy = B::Policy.new(B::Threshold.new(5, nil, 0), at(1), recovery, nil)
    forged = forge(policy, "i\x0A", "i\x00")
    assert_equal 0, forged.threshold.count
    error = assert_raises(RangeError) { B::Breaker.new(forged) }
    assert_match(/count/, error.message)
    assert_raises(RangeError) { B::Breaker.new(forge(policy, "i\x06", "i\x00")) }
  end

  def test_a_subclass_instance_is_refused
    sub = Class.new(Data.define(:count, :rate, :minimum_calls))
    impostor = sub.new(5, nil, 0)
    recovery = B::Recovery.new(at(1), 0.0, 1, 1)
    assert_raises(TypeError) { B::Policy.new(impostor, at(1), recovery, nil) }
  end

  def test_tickets_are_built_only_by_the_breaker
    assert_raises(NoMethodError, TypeError) { B::Ticket.new }
    assert_raises(TypeError) { B::Ticket.allocate }
  end

  def test_classes_survive_gc_compact
    GC.compact if GC.respond_to?(:compact)
    breaker = B::Breaker.new(policy)
    assert_instance_of B::Ticket, breaker.admit(0)
    assert_instance_of B::Policy, breaker.policy
    breaker.observe(:failure, 0, at(1), 0)
    assert_instance_of B::Event, breaker.events(1).first
  end
end
