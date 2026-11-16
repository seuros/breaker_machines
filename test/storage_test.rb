# frozen_string_literal: true

require_relative 'test_helper'
require 'active_support'
require 'active_support/cache'

class StorageTest < Minitest::Test
  include BreakerHelpers

  def setup
    @clock = ManualClock.new(at(1_000))
  end

  def teardown = B.registry.clear

  def circuit(storage, name: :shared, **runtime)
    B::Circuit.new(name, policy(failures: 1), storage:, clock: @clock, auto_register: false, **runtime)
  end

  def test_records_validate_and_round_trip
    status = B::Status.new(:open, at(1), at(31))
    record = B::Storage::Record.new(status, 3)
    assert_equal record, B::Storage::Record.load(record.dump)
    assert_raises(TypeError) { B::Storage::Record.new(:open, 1) }
    assert_raises(RangeError) { B::Storage::Record.new(status, -1) }
    assert_raises(B::StorageError) { B::Storage::Record.load([:open, at(31), at(1), 1]) }
    assert_raises(B::StorageError) { B::Storage::Record.load([:ajar, nil, nil, 1]) }
    assert_raises(RangeError) { B::Status.new(:closed, at(1), nil) }
  end

  def test_memory_storage_shares_the_lifecycle_between_circuits_of_a_name
    storage = B::Storage::Memory.new
    first = circuit(storage)
    second = circuit(storage)
    assert_raises(IOError) { first.call { raise IOError } }
    assert_predicate first, :open?
    assert_raises(B::CircuitOpenError) { second.call { :never } }
    assert_predicate second, :open?
    assert_equal first.opened_at, second.opened_at
    @clock.advance(at(30))
    assert_equal :ok, second.call { :ok }
    assert_predicate second, :closed?
    assert_equal :ok, first.call { :ok }, 'the recovery crossed over'
    assert_predicate first, :closed?
    assert_equal %i[failure success success], storage.event_log(:shared, 10).map(&:outcome)
  end

  def test_cache_storage_crosses_processes_through_a_shared_store
    store = ActiveSupport::Cache::MemoryStore.new
    here = circuit(B::Storage::Cache.new(store))
    there = circuit(B::Storage::Cache.new(store))
    assert_raises(IOError) { here.call { raise IOError } }
    assert_raises(B::CircuitOpenError) { there.call { :never } }
    assert_equal [:open, 1, 0], [there.state, here.events(5).size, there.breaker.failures(@clock.now)]
    there.reset
    assert_equal :closed, store.read('breaker_machines:shared:status').first, 'a reset is shared too'
    assert_nil store.read('breaker_machines:shared:events')
    assert_equal :ok, here.call { :ok }
    assert_predicate here, :closed?
  end

  def test_an_invalid_stored_record_is_never_adopted
    store = ActiveSupport::Cache::MemoryStore.new
    store.write('breaker_machines:shared:status', [:open, at(5), at(1), 9])
    c = circuit(B::Storage::Cache.new(store))
    assert_predicate c, :closed?
    assert_equal :ok, c.call { :ok }
  end

  def test_null_storage_shares_nothing
    first = circuit(B::Storage::Null.new)
    second = circuit(B::Storage::Null.new)
    assert_raises(IOError) { first.call { raise IOError } }
    assert_predicate second, :closed?
    assert_equal [], B::Storage::Null.new.event_log(:shared, 5)
  end

  def test_a_fallback_chain_skips_a_failing_backend
    broken = Object.new
    def broken.read_status(_) = raise(IOError, 'redis down')
    def broken.write_status(*) = raise(IOError, 'redis down')
    def broken.record_event(*) = raise(IOError, 'redis down')
    def broken.event_log(*) = raise(IOError, 'redis down')
    def broken.clear(_) = nil
    def broken.clear_all = nil
    memory = B::Storage::Memory.new
    chain = B::Storage::FallbackChain.new([broken, memory], clock: @clock)
    c = circuit(chain)
    assert_raises(IOError) { c.call { raise IOError } }
    assert_equal :open, memory.read_status(:shared).status.state
    failing = B::Storage::FallbackChain.new([broken], clock: @clock)
    assert_raises(B::StorageError) { failing.read_status(:x) }
    assert_raises(ArgumentError) { B::Storage::FallbackChain.new([]) }
  end

  def test_backends_type_check_what_they_store
    assert_raises(TypeError) { B::Storage::Memory.new.write_status(:x, :open) }
    assert_raises(TypeError) { B::Storage::Memory.new.record_event(:x, [1, :success, 0]) }
    assert_raises(TypeError) { B::Storage::Cache.new(Object.new) }
  end

  def test_a_storage_defaults_the_clock_to_wall_time
    c = B::Circuit.new(:wall, policy, storage: B::Storage::Memory.new, auto_register: false)
    assert_in_delta B.wall_time, c.now, at(5)
  end
end
