# frozen_string_literal: true

require 'test_helper'

class StorageCacheTest < ActiveSupport::TestCase
  class MockCache
    def initialize
      @data = {}
    end

    def read(key)
      @data[key]
    end

    def write(key, value, _options = {})
      @data[key] = value
    end

    def fetch(key, _options = {}, &block)
      @data[key] ||= block&.call
    end

    def delete(key)
      @data.delete(key)
    end

    def delete_matched(pattern)
      regex = Regexp.new(pattern.gsub('*', '.*'))
      @data.delete_if { |key, _| key.match?(regex) }
    end

    def increment(key, amount = 1, _options = {})
      @data[key] = (@data[key] || 0) + amount
    end
  end

  class MockCacheWithoutIncrement < MockCache
    # rubocop:disable Style/OptionalBooleanParameter
    def respond_to?(method, include_private = false)
      return false if method == :increment

      super
    end
    # rubocop:enable Style/OptionalBooleanParameter
  end

  setup do
    @cache = MockCache.new
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
    storage = BreakerMachines::Storage::Cache.new(cache_store: MockCacheWithoutIncrement.new)

    3.times { storage.record_failure('test_circuit', 0.1) }

    assert_operator storage.failure_count('test_circuit', 60), :>=, 3
  end
end
