# frozen_string_literal: true

require 'test_helper'

class StorageTest < ActiveSupport::TestCase
  def setup
    # Test the original Memory storage (not BucketMemory)
    @storage = BreakerMachines::Storage::Memory.new
    @circuit_name = :test_circuit
  end

  def test_get_status_returns_nil_for_unknown_circuit
    assert_nil @storage.get_status(:unknown_circuit)
  end

  def test_set_and_get_status
    @storage.set_status(@circuit_name, :open, 1_234_567_890)

    status = @storage.get_status(@circuit_name)

    assert_equal :open, status[:status]
    assert_equal 1_234_567_890, status[:opened_at]
  end

  def test_record_and_count_successes
    # Record some successes
    5.times { @storage.record_success(@circuit_name, 0.1) }

    # Count within window
    count = @storage.success_count(@circuit_name, 60)

    assert_equal 5, count

    # Count with very small window should be 0
    sleep 0.01 # Ensure events are outside the tiny window
    count = @storage.success_count(@circuit_name, 0.001)

    assert_equal 0, count
  end

  def test_record_and_count_failures
    # Record some failures
    3.times { @storage.record_failure(@circuit_name, 0.5) }

    # Count within window
    count = @storage.failure_count(@circuit_name, 60)

    assert_equal 3, count
  end

  def test_events_are_cleaned_up
    # Record an old event (mock old timestamp)
    @storage.instance_eval do
      @events[@circuit_name] = [{
        type: :failure,
        duration: 0.1,
        timestamp: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 400 # 6+ minutes ago
      }]
    end

    # Record new event (should clean old one)
    @storage.record_success(@circuit_name, 0.2)

    events = @storage.instance_variable_get(:@events)[@circuit_name]

    assert_equal 1, events.size
    assert_equal :success, events.first[:type]
  end

  def test_clear_circuit_data
    @storage.set_status(@circuit_name, :open)
    @storage.record_failure(@circuit_name, 0.1)

    @storage.clear(@circuit_name)

    assert_nil @storage.get_status(@circuit_name)
    assert_equal 0, @storage.failure_count(@circuit_name, 60)
  end

  def test_clear_all_data
    @storage.set_status(:circuit1, :open)
    @storage.set_status(:circuit2, :closed)
    @storage.record_failure(:circuit1, 0.1)
    @storage.record_success(:circuit2, 0.2)

    @storage.clear_all

    assert_nil @storage.get_status(:circuit1)
    assert_nil @storage.get_status(:circuit2)
    assert_equal 0, @storage.failure_count(:circuit1, 60)
    assert_equal 0, @storage.success_count(:circuit2, 60)
  end

  def test_thread_safety
    threads = []
    iterations = 100

    # Multiple threads writing
    5.times do |i|
      threads << Thread.new do
        iterations.times do
          @storage.record_success("circuit_#{i}", 0.01)
          @storage.record_failure("circuit_#{i}", 0.02)
        end
      end
    end

    # Multiple threads reading
    5.times do |i|
      threads << Thread.new do
        iterations.times do
          @storage.success_count("circuit_#{i}", 60)
          @storage.failure_count("circuit_#{i}", 60)
        end
      end
    end

    threads.each(&:join)

    # Verify data integrity
    5.times do |i|
      success_count = @storage.success_count("circuit_#{i}", 300)
      failure_count = @storage.failure_count("circuit_#{i}", 300)

      assert_equal iterations, success_count
      assert_equal iterations, failure_count
    end
  end
end
