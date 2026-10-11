# frozen_string_literal: true

require 'test_helper'

class StorageCacheTest < ActiveSupport::TestCase
  class CacheWithoutIncrement < ActiveSupport::Cache::MemoryStore
    def respond_to?(method, include_private = false)
      return false if method == :increment

      super
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

  test 'handles caches without increment method' do
    storage = BreakerMachines::Storage::Cache.new(cache_store: CacheWithoutIncrement.new)

    3.times { storage.record_failure('test_circuit', 0.1) }

    assert_operator storage.failure_count('test_circuit', 60), :>=, 3
  end
end
