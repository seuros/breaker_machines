# frozen_string_literal: true

require 'test_helper'

class StorageCacheTest < ActiveSupport::TestCase
  class CacheWithoutIncrement < ActiveSupport::Cache::MemoryStore
    def respond_to?(method, include_private = false)
      return false if method == :increment

      super
    end
  end

  # An increment-capable store with neither read_multi nor delete_multi.
  class MinimalCounterStore
    def initialize
      @data = {}
    end

    def read(key, _options = nil) = @data[key]
    def write(key, value, _options = nil) = (@data[key] = value)
    def delete(key) = @data.delete(key)
    def fetch(key, _options = nil) = (@data[key] ||= yield)
    def increment(key, amount = 1, _options = nil) = (@data[key] = (@data[key] || 0) + amount)
    def keys = @data.keys
  end

  class SlowWriteStore < ActiveSupport::Cache::MemoryStore
    def write(...)
      sleep 0.001
      super
    end
  end

  class StoreWithoutDeleteMatched < ActiveSupport::Cache::MemoryStore
    def delete_matched(_matcher, _options = nil)
      raise NotImplementedError, "#{self.class.name} does not support delete_matched"
    end
  end

  class RedisLikeStore < ActiveSupport::Cache::MemoryStore
    attr_reader :matchers

    def redis = nil

    def delete_matched(matcher, _options = nil)
      (@matchers ||= []) << matcher
    end
  end

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @storage = BreakerMachines::Storage::Cache.new(cache_store: @cache)
  end

  test 'persists circuit status' do
    @storage.set_status('test_circuit', :open, Time.now.to_f)
    status = @storage.get_status('test_circuit')

    assert_equal :open, status.status
    assert status.opened_at
  end

  test 'records and counts successes' do
    5.times { @storage.record_success('test_circuit', 0.1) }

    assert_equal 5, @storage.success_count('test_circuit', 60)
  end

  test 'records and counts failures' do
    3.times { @storage.record_failure('test_circuit', 0.1) }

    assert_equal 3, @storage.failure_count('test_circuit', 60)
  end

  %i[success failure].each do |type|
    test "#{type} counts exclude old events while traffic continues" do
      freeze_time
      @storage.public_send("record_#{type}", 'test_circuit', 0.1)
      travel 30.seconds
      @storage.public_send("record_#{type}", 'test_circuit', 0.1)
      travel 31.seconds
      @storage.public_send("record_#{type}", 'test_circuit', 0.1)

      assert_equal 2, @storage.public_send("#{type}_count", 'test_circuit', 60)
      assert_equal 1, @storage.public_send("#{type}_count", 'test_circuit', 10)
    end
  end

  test 'counts concurrent increments from separate adapters' do
    freeze_time
    threads = 8.times.map do
      Thread.new do
        storage = BreakerMachines::Storage::Cache.new(cache_store: @cache)
        100.times { storage.record_failure('test_circuit', 0.1) }
      end
    end
    threads.each(&:value)

    assert_equal 800, @storage.failure_count('test_circuit', 60)
  end

  test 'accepts fractional windows at second resolution' do
    freeze_time
    @storage.record_failure('test_circuit', 0.1)
    travel 1.second

    assert_equal 1, @storage.failure_count('test_circuit', 1.5)
    assert_equal 0, @storage.failure_count('test_circuit', 0)
  end

  test 'retains buckets for the configured expiry' do
    freeze_time
    storage = BreakerMachines::Storage::Cache.new(cache_store: @cache, expires_in: 600)
    storage.record_failure('test_circuit', 0.1)
    travel 301.seconds

    assert_equal 1, storage.failure_count('test_circuit', 600)
    assert_equal 0, storage.failure_count('test_circuit', 60)
  end

  test 'clears earlier buckets without clearing another circuit' do
    freeze_time
    @storage.record_failure('test_circuit', 0.1)
    @storage.record_success('test_circuit', 0.1)
    @storage.record_failure('other_circuit', 0.1)
    travel 30.seconds
    @storage.record_failure('test_circuit', 0.1)

    @storage.clear('test_circuit')

    assert_equal 0, @storage.failure_count('test_circuit', 60)
    assert_equal 0, @storage.success_count('test_circuit', 60)
    assert_equal 1, @storage.failure_count('other_circuit', 60)
  end

  test 'clears circuit data' do
    @storage.set_status('test_circuit', :open)
    @storage.record_success('test_circuit', 0.1)
    @storage.record_failure('test_circuit', 0.1)

    @storage.clear('test_circuit')

    assert_nil @storage.get_status('test_circuit')
    assert_equal 0, @storage.success_count('test_circuit', 60)
    assert_equal 0, @storage.failure_count('test_circuit', 60)
  end

  test 'clears all circuit data with pattern support' do
    @storage.set_status('circuit1', :open)
    @storage.set_status('circuit2', :closed)

    @storage.clear_all

    assert_nil @storage.get_status('circuit1')
    assert_nil @storage.get_status('circuit2')
  end

  test 'logs events with details' do
    @storage.record_event_with_details(
      'test_circuit',
      :failure,
      0.5,
      error: StandardError.new('Test error'),
      new_state: :open
    )

    events = @storage.event_log('test_circuit', 10)

    assert_equal 1, events.size
    assert_equal :failure, events.first[:type]
    assert_equal 'StandardError', events.first[:error_class]
    assert_equal 'Test error', events.first[:error_message]
    assert_equal :open, events.first[:new_state]
  end

  test 'keeps every event appended concurrently from separate adapters' do
    store = SlowWriteStore.new
    threads = 8.times.map do
      Thread.new do
        storage = BreakerMachines::Storage::Cache.new(cache_store: store)
        10.times { storage.record_event_with_details('test_circuit', :failure, 0.1) }
      end
    end
    threads.each(&:value)

    assert_equal 80, BreakerMachines::Storage::Cache.new(cache_store: store).event_log('test_circuit', 100).size
  end

  test 'keeps the most recent max_events events in order' do
    storage = BreakerMachines::Storage::Cache.new(cache_store: @cache, max_events: 5)
    8.times { |i| storage.record_event_with_details('test_circuit', :success, i / 1000.0) }

    assert_equal [3.0, 4.0, 5.0, 6.0, 7.0], storage.event_log('test_circuit', 10).pluck(:duration_ms)
    assert_equal [6.0, 7.0], storage.event_log('test_circuit', 2).pluck(:duration_ms)
  end

  test 'orders events by time after the sequence restarts' do
    3.times { |i| @storage.record_event_with_details('test_circuit', :success, i / 1000.0) }
    @cache.delete('breaker_machines:test_circuit:event_sequence')
    @storage.record_event_with_details('test_circuit', :failure, 0.009)

    events = @storage.event_log('test_circuit', 10)

    assert_equal [1.0, 2.0, 9.0], events.pluck(:duration_ms)
    assert_equal :failure, events.last[:type]
  end

  test 'reads events from another host in local monotonic time' do
    epoch = Process.clock_gettime(Process::CLOCK_REALTIME) - 30
    @cache.write('breaker_machines:test_circuit:event:1',
                 { type: :failure, timestamp: BreakerMachines.monotonic_time + 50_000,
                   timestamp_epoch: epoch, duration_ms: 1.0, sequence: 1 })

    event = @storage.event_log('test_circuit', 1).first

    assert_in_delta BreakerMachines.monotonic_time - 30, event[:timestamp], 0.5
    assert_in_delta epoch, event[:timestamp_epoch], 0.001
    assert_nil event[:sequence]
  end

  test 'clears logged events' do
    @storage.record_event_with_details('test_circuit', :failure, 0.1)
    @storage.clear('test_circuit')

    assert_empty @storage.event_log('test_circuit', 10)
  end

  test 'rejects a non-positive event limit' do
    assert_raises(ArgumentError) { BreakerMachines::Storage::Cache.new(cache_store: @cache, max_events: 0) }
  end

  test 'logs events with caches without increment method' do
    storage = BreakerMachines::Storage::Cache.new(cache_store: CacheWithoutIncrement.new, max_events: 2)
    3.times { |i| storage.record_event_with_details('test_circuit', :success, i / 1000.0) }

    assert_equal [1.0, 2.0], storage.event_log('test_circuit', 10).pluck(:duration_ms)
  end

  test 'clears all circuit data within a namespace only' do
    namespaced = ActiveSupport::Cache::MemoryStore.new(namespace: 'app')
    storage = BreakerMachines::Storage::Cache.new(cache_store: namespaced)
    namespaced.write('unrelated', 'kept')
    storage.set_status('circuit1', :open)

    storage.clear_all

    assert_nil storage.get_status('circuit1')
    assert_equal 'kept', namespaced.read('unrelated')
  end

  test 'clears all with a glob on redis stores' do
    store = RedisLikeStore.new
    BreakerMachines::Storage::Cache.new(cache_store: store, prefix: 'cb[1]').clear_all

    assert_equal ['cb\[1\]:*'], store.matchers
  end

  test 'warns instead of raising when the store cannot delete by pattern' do
    log = StringIO.new
    previous_logger = BreakerMachines.logger
    BreakerMachines.logger = Logger.new(log)

    BreakerMachines::Storage::Cache.new(cache_store: StoreWithoutDeleteMatched.new).clear_all

    assert_includes log.string, "StoreWithoutDeleteMatched doesn't support delete_matched"
  ensure
    BreakerMachines.logger = previous_logger
  end

  test 'handles caches without increment method' do
    storage = BreakerMachines::Storage::Cache.new(cache_store: CacheWithoutIncrement.new)

    3.times { storage.record_failure('test_circuit', 0.1) }

    assert_operator storage.failure_count('test_circuit', 60), :>=, 3
  end

  test 'counts in coarser buckets when configured' do
    freeze_time
    store = MinimalCounterStore.new
    storage = BreakerMachines::Storage::Cache.new(cache_store: store, bucket_seconds: 10)
    travel_to Time.at((Time.now.to_i / 10 * 10) + 1)
    2.times { storage.record_failure('test_circuit', 0.1) }
    travel 5.seconds
    storage.record_failure('test_circuit', 0.1)

    assert_equal 3, storage.failure_count('test_circuit', 60)
    assert_equal 1, store.keys.grep(/:failures:/).size

    travel 65.seconds

    assert_equal 0, storage.failure_count('test_circuit', 60)
  end

  test 'rejects a non-positive bucket size' do
    assert_raises(ArgumentError) { BreakerMachines::Storage::Cache.new(cache_store: @cache, bucket_seconds: 0) }
  end

  test 'counts and clears with stores lacking read_multi and delete_multi' do
    freeze_time
    store = MinimalCounterStore.new
    storage = BreakerMachines::Storage::Cache.new(cache_store: store)
    storage.record_failure('test_circuit', 0.1)
    travel 30.seconds
    storage.record_failure('test_circuit', 0.1)

    assert_equal 2, storage.failure_count('test_circuit', 60)
    assert_equal 1, storage.failure_count('test_circuit', 10)

    storage.clear('test_circuit')

    assert_equal 0, storage.failure_count('test_circuit', 60)
    assert_empty store.keys.grep(/:failures:/)
  end

  test 'warns once when a window outlives the counter retention' do
    log = StringIO.new
    previous_logger = BreakerMachines.logger
    BreakerMachines.logger = Logger.new(log)
    storage = BreakerMachines::Storage::Cache.new(cache_store: @cache, expires_in: 300)

    2.times { storage.failure_count('test_circuit', 600) }
    storage.failure_count('test_circuit', 300)

    assert_equal 1, log.string.scan('only sees the last 300s').size
  ensure
    BreakerMachines.logger = previous_logger
  end

  test 'reads the opening time of another host from its epoch copy' do
    epoch = Process.clock_gettime(Process::CLOCK_REALTIME) - 30
    # A host whose monotonic clock started 50,000 seconds before ours.
    @cache.write('breaker_machines:test_circuit:status',
                 { status: :open, opened_at: BreakerMachines.monotonic_time + 50_000, opened_at_epoch: epoch })

    opened_at = @storage.get_status('test_circuit').opened_at

    assert_in_delta BreakerMachines.monotonic_time - 30, opened_at, 0.5
  end

  test 'round-trips its own opening time' do
    opened_at = BreakerMachines.monotonic_time
    @storage.set_status('test_circuit', :open, opened_at)

    assert_in_delta opened_at, @storage.get_status('test_circuit').opened_at, 0.001
  end

  test 'falls back to the monotonic opening time of entries without an epoch copy' do
    @cache.write('breaker_machines:test_circuit:status', { status: :open, opened_at: 123.5 })

    assert_equal 123.5, @storage.get_status('test_circuit').opened_at
  end

  test 'reports a failed status write' do
    @cache.stub(:write, false) do
      assert_equal false, @storage.set_status('test_circuit', :open, BreakerMachines.monotonic_time)
    end
  end
end
