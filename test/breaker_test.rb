# frozen_string_literal: true

require_relative 'test_helper'

class BreakerTest < Minitest::Test
  include BreakerHelpers

  # Bug: retry_at is now + cooldown, past 2**64-1 nanoseconds, but every
  # `now` was read as a u64, so an instant the breaker returned raised
  # RangeError when handed back. Every instant reads the whole range now.
  def test_every_instant_the_breaker_returns_reads_back
    last = (2**64) - 1
    breaker = B::Breaker.new(B::Policy.new(B::Threshold.new(1, nil, 0), at(60), B::Recovery.new(1, 0.0, 1, 1), nil))
    assert_equal :opened, breaker.force_open(last, 0)
    retry_at = breaker.retry_at
    assert_equal 2**64, retry_at
    assert_equal 0, breaker.retry_after(retry_at)
    assert_equal 0, breaker.failures(retry_at)
    assert_equal 0, breaker.successes(retry_at)
    ticket = breaker.admit(retry_at)
    assert_instance_of B::Ticket, ticket
    assert_equal retry_at, ticket.admitted_at
    assert_equal :opened, breaker.complete(ticket, :failure, retry_at, 0)
    assert_equal :counted, breaker.observe(:success, retry_at, breaker.retry_at - 1, 0)
    assert_equal :opened, breaker.force_open(breaker.retry_at, 0)
    event = breaker.events(1).first
    assert_equal event, B::Event.new(event.at, event.outcome, event.took)
  end

  def test_a_closed_breaker_admits_calls_and_counts_outcomes
    breaker = B::Breaker.new(policy)
    assert_equal :closed, breaker.state
    ticket = breaker.admit(at(1))
    assert_instance_of B::Ticket, ticket
    assert_equal [:call, :call, at(1), nil], [ticket.kind, ticket.admission, ticket.admitted_at, ticket.settled]
    assert_equal 1, breaker.outstanding
    assert_equal :counted, breaker.complete(ticket, :success, at(3), 0)
    assert_equal [:success, :counted], ticket.settled
    assert_predicate ticket.settled, :frozen?
    assert_equal [B::Event.new(at(3), :success, at(2))], breaker.events(10)
    assert_equal [1, 0, 0], [breaker.successes(at(3)), breaker.failures(at(3)), breaker.outstanding]
  end

  def test_the_threshold_opens_and_the_cooldown_refuses_until_due
    breaker = opened(at(10))
    assert_equal [:open, at(10), at(40)], [breaker.state, breaker.opened_at, breaker.retry_at]
    assert_equal at(15), breaker.retry_after(at(25))
    assert_refused(:open, breaker) { breaker.admit(at(39)) }
    probe = breaker.admit(at(40))
    assert_equal %i[probe half_opened], [probe.kind, probe.admission]
    assert_refused(:busy, breaker) { breaker.admit(at(41)) }
    assert_equal :closed, breaker.complete(probe, :success, at(41), 0)
    assert_equal 0, breaker.failures(at(41)), 'a recovered circuit starts a fresh window'
  end

  def test_a_failed_probe_reopens_with_a_fresh_cooldown
    breaker = opened
    probe = breaker.admit(at(30))
    assert_equal :opened, breaker.complete(probe, :failure, at(35), 0)
    assert_equal at(65), breaker.retry_at
  end

  def test_repeats_are_duplicates_and_other_settlements_mismatches
    breaker = B::Breaker.new(policy(failures: 1))
    ticket = breaker.admit(0)
    assert_equal :opened, breaker.complete(ticket, :failure, at(1), 0)
    assert_repeat(:duplicate, breaker) { breaker.complete(ticket, :failure, 0, 0) }
    assert_refused(:mismatch, breaker) { breaker.complete(ticket, :success, at(1), 0) }
    assert_refused(:mismatch, breaker) { breaker.abandon(ticket) }
    breaker.reset
    dropped = breaker.admit(at(1))
    assert_equal :released, breaker.abandon(dropped)
    assert_equal :abandoned, dropped.settled
    assert_repeat(:duplicate, breaker) { breaker.abandon(dropped) }
  end

  def test_time_regression_and_foreign_tickets_are_refused
    breaker = B::Breaker.with_scope(policy, 1)
    ticket = breaker.admit(at(10))
    assert_refused(:time_regression, breaker) { breaker.admit(at(9)) }
    assert_refused(:time_regression, breaker) { breaker.complete(ticket, :success, at(9), 0) }
    assert_refused(:time_regression, breaker) { breaker.observe(:failure, 0, at(9), 0) }
    assert_refused(:time_regression, breaker) { breaker.force_open(at(9), 0) }
    assert_nil ticket.settled
    foreign = B::Breaker.with_scope(policy, 2).admit(0)
    assert_refused(:unknown, breaker) { breaker.complete(foreign, :failure, at(10), 0) }
    assert_equal 1, breaker.scope
  end

  def test_the_concurrency_limit_is_full_until_a_ticket_returns
    breaker = B::Breaker.new(policy(limit: 1))
    ticket = breaker.admit(0)
    assert_refused(:full, breaker) { breaker.admit(0) }
    breaker.abandon(ticket)
    assert_instance_of B::Ticket, breaker.admit(0)
  end

  def test_observe_force_and_reset
    breaker = B::Breaker.new(policy(failures: 1))
    assert_equal :opened, breaker.observe(:failure, at(1), at(1), 0)
    assert_equal :counted, breaker.observe(:failure, 0, at(2), 0)
    assert_equal :half_opened_and_closed, breaker.observe(:success, 0, at(31), 0)
    assert_repeat(:already_closed, breaker) { breaker.force_close }
    assert_equal :opened, breaker.force_open(at(32), 0)
    assert_equal :closed, breaker.force_close
    assert_nil breaker.reset
    assert_empty breaker.events(10)
    reopened = B::Breaker.new(policy(failures: 1))
    reopened.force_open(0, 0)
    assert_equal :half_opened_and_reopened, reopened.observe(:failure, 0, at(30), 0)
    watching = B::Breaker.new(policy(failures: 1, successes: 2))
    watching.force_open(0, 0)
    assert_equal :half_opened, watching.observe(:success, 0, at(30), 0)
  end

  def test_jitter_is_drawn_from_the_callers_draw
    breaker = B::Breaker.new(policy(jitter: 0.5))
    breaker.force_open(0, 2**63)
    assert_operator breaker.retry_at, :<, at(30)
    assert_operator breaker.retry_at, :>=, at(15)
    assert_raises(RangeError) { breaker.force_open(at(1), 2**64) }
    assert_raises(RangeError) { breaker.force_open(at(1), -1) }
  end

  def test_arguments_are_converted_before_the_core_runs
    breaker = B::Breaker.new(policy)
    ticket = breaker.admit(0)
    before = snapshot(breaker)
    assert_raises(TypeError) { breaker.admit(1.5) }
    assert_raises(RangeError) { breaker.complete(ticket, :timeout, 0, 0) }
    assert_raises(TypeError) { breaker.complete(:ticket, :success, 0, 0) }
    assert_raises(TypeError) { breaker.events('10') }
    assert_raises(TypeError) { B::Breaker.new({}) }
    assert_raises(RangeError) { B::Breaker.with_scope(policy, 70_000) }
    assert_equal before, snapshot(breaker)
  end

  def test_frozen_breakers_and_tickets_refuse_mutation
    breaker = B::Breaker.new(policy)
    ticket = breaker.admit(0)
    ticket.freeze
    assert_raises(FrozenError) { breaker.complete(ticket, :success, 0, 0) }
    breaker.freeze
    assert_raises(FrozenError) { breaker.admit(0) }
    assert_raises(FrozenError) { breaker.reset }
    assert_equal :closed, breaker.state
  end

  def test_the_policy_round_trips
    assert_equal policy(limit: 4), B::Breaker.new(policy(limit: 4)).policy
  end

  def test_a_status_crosses_over_through_adopt
    source = opened(at(5))
    status = source.status
    assert_equal B::Status.new(:open, at(5), at(35)), status
    mirror = B::Breaker.new(policy)
    held = mirror.admit(at(1))
    assert_equal :opened, mirror.adopt(status)
    assert_repeat(:unchanged, mirror) { mirror.adopt(status) }
    assert_equal :counted, mirror.complete(held, :failure, at(6), 0), 'tickets from before are fenced'
    assert_equal :half_opened, mirror.adopt(B::Status.new(:half_open, nil, nil))
    assert_equal :closed, mirror.adopt(B::Status.new(:closed, nil, nil))
    assert_equal 0, mirror.failures(at(6))
    assert_raises(TypeError) { mirror.adopt([:open, 1, 2]) }
    assert_raises(RangeError) { B::Status.new(:half_open, at(1), nil) }
    assert_raises(RangeError) { B::Status.new(:ajar, nil, nil) }
  end
end
