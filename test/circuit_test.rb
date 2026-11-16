# frozen_string_literal: true

require_relative 'test_helper'

class CircuitTest < Minitest::Test
  include BreakerHelpers

  def setup
    @clock = ManualClock.new
    @seen = []
  end

  def teardown = B.registry.clear

  def circuit(policy = self.policy, **runtime)
    hooks = %i[on_open on_close on_half_open on_reject].to_h { |hook| [hook, -> { @seen << hook }] }
    B::Circuit.new(:svc, policy, clock: @clock, **hooks, **runtime)
  end

  def fail(circuit) = circuit.call { raise IOError, 'down' }

  def test_a_full_cycle_fires_each_hook_once
    c = circuit(policy(failures: 2))
    assert_equal 7, c.call { 7 }
    2.times { assert_raises(IOError) { fail(c) } }
    assert_predicate c, :open?
    error = assert_raises(B::CircuitOpenError) { c.call { 1 } }
    assert_equal [:svc, :open, at(30)], [error.circuit_name, error.refusal, error.retry_after]
    @clock.advance(at(30))
    assert_equal :up, c.call { :up }
    assert_predicate c, :closed?
    assert_equal %i[on_open on_reject on_half_open on_close], @seen
  end

  def test_fallbacks_replace_refusals_and_failures
    c = circuit(policy(failures: 1), fallback: ->(error) { "fallback: #{error.class}" })
    assert_equal 'fallback: IOError', fail(c)
    assert_equal 'fallback: BreakerMachines::CircuitOpenError', c.call { :live }
    chained = circuit(policy(failures: 1), fallback: [-> { raise 'first' }, ->(error) { error.message }, :never])
    assert_equal 'first', fail(chained)
    static = circuit(policy(failures: 1), fallback: :cached)
    assert_equal :cached, fail(static)
  end

  def test_only_listed_exceptions_count
    c = circuit(policy(failures: 1), exceptions: [IOError])
    assert_raises(ArgumentError) { c.call { raise ArgumentError } }
    assert_predicate c, :closed?
    assert_equal 0, c.stats.failure_count
    assert_equal 0, c.instance_variable_get(:@breaker).outstanding, 'the uncounted call was abandoned'
    catch(:out) { c.call { throw :out } }
    assert_equal 0, c.instance_variable_get(:@breaker).outstanding
  end

  def test_the_concurrency_limit_raises_a_bulkhead_error
    c = circuit(policy(limit: 1))
    c.call do
      error = assert_raises(B::CircuitBulkheadError) { c.call { :inner } }
      assert_equal :full, error.refusal
    end
  end

  def test_stats_observe_force_and_reset
    c = circuit(policy(failures: 1))
    @clock.advance(at(5))
    assert_raises(IOError) { fail(c) }
    stats = c.stats
    assert_equal [:open, 1, 0, at(5), at(5)], stats.to_h.values_at(:state, :failure_count, :success_count,
                                                                    :last_failure_at, :opened_at)
    assert_instance_of IOError, c.last_error
    c.reset
    assert_nil c.last_error
    assert_equal :open, c.observe(:failure, 0)
    @clock.advance(at(30))
    assert_equal :closed, c.observe(:success, 0)
    assert_same c, c.force_open
    assert_same c, c.force_close
    assert_same c, c.force_close
    assert_equal %i[on_open on_open on_half_open on_close on_open on_close], @seen
    assert_equal :svc, c.to_h[:name]
    assert_empty c.events, 'recovering by probe starts a fresh window'
  end

  def test_a_clock_that_steps_back_reads_as_standing_still
    c = circuit
    @clock.advance(at(10))
    c.call { 1 }
    @clock.advance(-at(5))
    assert_equal at(10), c.now
    assert_equal 1, c.call { 1 }
  end

  def test_hooks_and_fallbacks_run_on_their_owner
    owner = Struct.new(:calls).new([])
    c = B::Circuit.new(:owned, policy(failures: 1), owner:, on_open: -> { calls << :open },
                                                    fallback: -> { calls << :fallback })
    fail(c)
    assert_equal %i[open fallback], owner.calls
  end

  def test_a_raising_hook_is_ignored
    c = B::Circuit.new(:loud, policy(failures: 1), on_open: -> { raise 'hook' })
    assert_raises(IOError) { fail(c) }
    assert_predicate c, :open?
  end

  def test_call_needs_a_block_and_wrap_is_call
    assert_raises(ArgumentError) { circuit.call }
    assert_equal 3, circuit.wrap { 3 }
  end

  def test_a_spent_deadline_is_abandoned_not_counted
    c = circuit(policy(failures: 1))
    assert_raises(DeadlineMachines::Error) do
      DeadlineMachines.with_deadline(1) do
        sleep 0.001
        c.call { DeadlineMachines.check! }
      end
    end
    assert_predicate c, :closed?
    assert_equal 0, c.stats.failure_count
  end
end
