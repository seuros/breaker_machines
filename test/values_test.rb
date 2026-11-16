# frozen_string_literal: true

require_relative 'test_helper'

class ValuesTest < Minitest::Test
  include BreakerHelpers

  def test_values_take_the_core_arguments_positionally_or_by_keyword
    threshold = B::Threshold.new(5, 0.5, 10)
    assert_equal threshold, B::Threshold.new(count: 5, rate: 0.5, minimum_calls: 10)
    recovery = B::Recovery.new(at(30), 0.25, 2, 3)
    assert_equal [at(30), 0.25, 2, 3], recovery.to_h.values
    policy = B::Policy.new(threshold, at(60), recovery, 8)
    assert_equal [threshold, at(60), recovery, 8], policy.to_h.values
    assert_equal B::Event.new(at(1), :failure, at(2)), B::Event.new(at: at(1), outcome: :failure, took: at(2))
  end

  def test_threshold_needs_a_count_or_a_valid_rate
    assert_raises(RangeError) { B::Threshold.new(nil, nil, 0) }
    [0.0, -0.1, 1.5, Float::NAN, Float::INFINITY].each do |rate|
      assert_raises(RangeError, rate.inspect) { B::Threshold.new(nil, rate, 1) }
    end
    assert_raises(RangeError) { B::Threshold.new(0, nil, 0) }
    assert_raises(RangeError) { B::Threshold.new(1, nil, -1) }
    assert_raises(TypeError) { B::Threshold.new('5', nil, 0) }
    assert_raises(TypeError) { B::Threshold.new(5, '0.5', 0) }
    assert_equal 1, B::Threshold.new(nil, 1, 0).rate
  end

  def test_recovery_validates_its_spans_jitter_and_counts
    assert_raises(TypeError) { B::Recovery.new(30.0, 0.0, 1, 1) }
    assert_raises(RangeError) { B::Recovery.new(-1, 0.0, 1, 1) }
    assert_raises(RangeError) { B::Recovery.new(2**64, 0.0, 1, 1) }
    assert_raises(RangeError) { B::Recovery.new(1, 1.01, 1, 1) }
    assert_raises(RangeError) { B::Recovery.new(1, 0.0, 0, 1) }
    assert_raises(RangeError) { B::Recovery.new(1, 0.0, 1, 0) }
    assert_raises(TypeError) { B::Recovery.new(1, nil, 1, 1) }
  end

  def test_policy_validates_its_parts_by_exact_class
    threshold = B::Threshold.new(5, nil, 0)
    recovery = B::Recovery.new(at(1), 0.0, 1, 1)
    assert_raises(RangeError) { B::Policy.new(threshold, 0, recovery, nil) }
    assert_raises(RangeError) { B::Policy.new(threshold, at(1), recovery, 0) }
    assert_raises(TypeError) { B::Policy.new(recovery, at(1), recovery, nil) }
    assert_raises(TypeError) { B::Policy.new(threshold, at(1), { cooldown: 1 }, nil) }
  end

  def test_events_validate
    assert_raises(RangeError) { B::Event.new(0, :timeout, 0) }
    assert_raises(TypeError) { B::Event.new(0, 'success', 0) }
    assert_raises(TypeError) { B::Event.new(0.5, :success, 0) }
  end

  def test_values_are_sealed_and_frozen
    [B::Threshold, B::Recovery, B::Policy, B::Status, B::Event].each do |value|
      assert_raises(NoMethodError) { value.allocate }
      assert_raises(TypeError) { Class.new(value) }
    end
    assert_predicate policy, :frozen?
  end

  # Breaker and Ticket wrap native state with no allocator: a subclass's
  # `new` would build the base class anyway.
  def test_native_wrappers_are_sealed
    [B::Breaker, B::Ticket].each do |wrapper|
      assert_raises(TypeError) { wrapper.allocate }
      assert_raises(TypeError) { Class.new(wrapper) }
    end
  end

  def test_runtime_values_are_sealed
    [B::Storage::Record, B::CascadeInfo, B::Stats].each do |value|
      refute_respond_to value, :allocate
      assert_raises(TypeError) { Class.new(value) }
    end
  end

  def test_tables_list_every_symbol
    assert_equal %i[open busy full time_regression unknown mismatch exhausted], B::REFUSALS
    assert_equal %i[closed open half_open], B::STATES
    assert_equal %i[success failure], B::OUTCOMES
    assert_predicate B::REFUSALS, :frozen?
  end
end
