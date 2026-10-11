# frozen_string_literal: true

require 'test_helper'

class SharedCircuitTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @first = build_circuit
    @second = build_circuit
  end

  test 'rejects calls after another instance opens the circuit' do
    @first.trip

    assert_raises(BreakerMachines::CircuitOpenError) do
      @second.call { flunk 'An open circuit must not run the operation' }
    end
    assert_predicate @second, :open?
  end

  test 'observes a reset by another instance and clears the opening time' do
    @first.trip
    @second = build_circuit
    @first.reset

    assert_equal :ok, @second.call { :ok }
    assert_predicate @second, :closed?
    assert_nil @second.opened_at.value
  end

  test 'does not replay transition callbacks when refreshing state' do
    @second = build_circuit(on_open: -> { flunk 'Must not replay the other instance callback' })
    @first.trip

    assert_raises(BreakerMachines::CircuitOpenError) { @second.call { :ok } }
  end

  test 'preserves probe admission when stored state has not changed' do
    @first.trip
    @first.attempt_recovery

    @second.call do
      assert_raises(BreakerMachines::CircuitOpenError) { @second.call { :extra_probe } }
      :ok
    end

    assert_predicate @second, :closed?
  end

  test 'ignores a successful probe after another instance reopens the circuit' do
    @first.trip
    @first.attempt_recovery

    @second.call do
      @first.trip
      :ok
    end

    assert_predicate @second, :open?
    assert_equal :open, @first.storage.get_status('shared').status
  end

  test 'ignores a failed call from before another instance entered recovery' do
    assert_raises(IOError) do
      @second.call do
        @first.trip
        @first.attempt_recovery
        raise IOError
      end
    end

    assert_predicate @second, :half_open?
    assert_equal :half_open, @first.storage.get_status('shared').status
  end

  test 'starts fresh probe counters after observing another recovery' do
    @second = build_circuit(half_open_calls: 2, success_threshold: 100)
    @second.trip
    @second.attempt_recovery
    @second.call { :ok }
    assert_equal 1, @second.half_open_successes.value

    @first.call do
      @first.trip
      @first.attempt_recovery
    end
    @second.call { :ok }

    assert_predicate @second, :half_open?
    assert_equal 1, @second.half_open_successes.value
  end

  private

  def build_circuit(**options)
    storage = BreakerMachines::Storage::Cache.new(cache_store: @cache)
    BreakerMachines::Circuit.new('shared', {
      storage: storage,
      failure_threshold: 1,
      reset_timeout: 3600,
      reset_timeout_jitter: 0,
      auto_register: false
    }.merge(options))
  end
end
