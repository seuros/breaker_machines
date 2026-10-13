# frozen_string_literal: true

require 'test_helper'

class SharedCircuitTest < ActiveSupport::TestCase
  class StatusWriteFailingStore < ActiveSupport::Cache::MemoryStore
    attr_accessor :fail_status_writes

    def write(name, value, options = nil)
      return false if fail_status_writes && name.to_s.end_with?(':status')

      super
    end
  end

  class WriteLockCounter < SimpleDelegator
    attr_reader :write_locks

    def initialize(lock)
      super
      @write_locks = 0
    end

    def with_write_lock(&)
      @write_locks += 1
      __getobj__.with_write_lock(&)
    end
  end

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

  [BreakerMachines::Circuit, BreakerMachines::CoordinatedCircuit,
   BreakerMachines::CascadingCircuit, BreakerMachines::AsyncCircuit].each do |circuit_class|
    test "restores an open circuit when constructing #{circuit_class}" do
      skip_async_dependent_test if circuit_class == BreakerMachines::AsyncCircuit
      @first.trip
      circuit = build_circuit(circuit_class:, on_open: -> { flunk 'Must not replay the opening callback' })

      assert_raises(BreakerMachines::CircuitOpenError) do
        circuit.call { flunk 'An open circuit must not run the operation' }
      end
      assert_predicate circuit, :open?
      assert_in_delta @first.opened_at.value, circuit.opened_at.value, 0.001
    end
  end

  test 'restores half-open probe admission on construction' do
    @first.trip
    @first.attempt_recovery
    circuit = build_circuit

    assert_predicate circuit, :half_open?
    circuit.call do
      assert_raises(BreakerMachines::CircuitOpenError) { circuit.call { :extra_probe } }
      :ok
    end
    assert_predicate circuit, :closed?
  end

  test 'recovers on its first call when constructed after the cooldown' do
    write_peer_status(:open, opened_seconds_ago: 3601, clock_skew: 50_000)
    circuit = build_circuit

    assert_predicate circuit, :open?
    assert_equal :ok, circuit.call { :ok }
    assert_predicate circuit, :closed?
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

  test 'measures the reset timeout from when another host opened the circuit' do
    write_peer_status(:open, opened_seconds_ago: 1, clock_skew: -50_000)

    assert_raises(BreakerMachines::CircuitOpenError) do
      @second.call { flunk 'A circuit opened a second ago must stay open' }
    end
    assert_equal :open, @first.storage.get_status('shared').status
  end

  test 'recovers once the reset timeout has passed since another host opened the circuit' do
    write_peer_status(:open, opened_seconds_ago: 3601, clock_skew: 50_000)

    assert_equal :ok, @second.call { :ok }
    assert_predicate @second, :closed?
  end

  test 'keeps its own trip when the shared status write fails' do
    @cache = StatusWriteFailingStore.new
    circuit = build_circuit
    circuit.storage.set_status('shared', :closed)
    circuit.call { :ok }

    @cache.fail_status_writes = true
    assert_raises(IOError) { circuit.call { raise IOError } }
    @cache.fail_status_writes = false

    assert_raises(BreakerMachines::CircuitOpenError) do
      circuit.call { flunk 'A stale stored status must not undo the trip' }
    end
  end

  test 'admits calls without the write lock while the shared status is unchanged' do
    lock = WriteLockCounter.new(@second.mutex)
    @second.instance_variable_set(:@mutex, lock)

    5.times { @second.call { :ok } }

    assert_equal 0, lock.write_locks

    @first.trip

    assert_raises(BreakerMachines::CircuitOpenError) { @second.call { :ok } }
    assert_equal 1, lock.write_locks
  end

  test 'runs without a storage backend' do
    previous_storage = BreakerMachines.config.default_storage
    BreakerMachines.config.default_storage = nil
    circuit = BreakerMachines::Circuit.new('no_storage', auto_register: false)

    assert_nil circuit.storage
    assert_equal :ok, circuit.call { :ok }

    circuit.trip

    assert_predicate circuit, :open?
  ensure
    BreakerMachines.config.default_storage = previous_storage
  end

  private

  # What another host writes: its monotonic clock is clock_skew seconds away
  # from ours, its epoch copy is exact.
  def write_peer_status(status, opened_seconds_ago:, clock_skew:)
    @cache.write('breaker_machines:shared:status', {
                   status: status,
                   opened_at: BreakerMachines.monotonic_time - opened_seconds_ago + clock_skew,
                   opened_at_epoch: Process.clock_gettime(Process::CLOCK_REALTIME) - opened_seconds_ago
                 })
  end

  def build_circuit(circuit_class: BreakerMachines::Circuit, **options)
    storage = BreakerMachines::Storage::Cache.new(cache_store: @cache)
    circuit_class.new('shared', {
      storage: storage,
      failure_threshold: 1,
      reset_timeout: 3600,
      reset_timeout_jitter: 0,
      auto_register: false
    }.merge(options))
  end
end
