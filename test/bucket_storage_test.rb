# frozen_string_literal: true

require 'test_helper'

class BucketStorageTest < ActiveSupport::TestCase
  def setup
    @storage = BreakerMachines::Storage::BucketMemory.new(bucket_count: 60) # 1 minute
    @circuit_name = :test_circuit
  end

  def test_get_status_returns_nil_for_unknown_circuit
    assert_nil @storage.get_status(:unknown_circuit)
  end

  def test_set_and_get_status
    @storage.set_status(@circuit_name, :open, 1_234_567_890)

    status = @storage.get_status(@circuit_name)

    assert_equal :open, status.status
    assert_equal 1_234_567_890, status.opened_at
  end

  def test_record_and_count_successes
    # Record some successes
    5.times { @storage.record_success(@circuit_name, 0.1) }

    # Count within window
    count = @storage.success_count(@circuit_name, 60)

    assert_equal 5, count

    # Count with very small window should be 0
    sleep 1.1 # Move to next bucket
    count = @storage.success_count(@circuit_name, 1)

    assert_equal 0, count
  end

  def test_record_and_count_failures
    # Record some failures
    3.times { @storage.record_failure(@circuit_name, 0.5) }

    # Count within window
    count = @storage.failure_count(@circuit_name, 60)

    assert_equal 3, count
  end

  def test_bucket_rotation
    # Record events in different time buckets
    @storage.record_success(@circuit_name, 0.1)
    sleep 1.1 # Move to next bucket
    @storage.record_success(@circuit_name, 0.1)
    sleep 1.1 # Move to next bucket
    @storage.record_success(@circuit_name, 0.1)

    # Should count all events within 4 second window (to account for timing)
    count = @storage.success_count(@circuit_name, 4)

    assert_equal 3, count

    # Should only count recent events in 1 second window
    count = @storage.success_count(@circuit_name, 1)

    assert_equal 1, count
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

  def test_performance_comparison
    # This test demonstrates the performance improvement
    circuit_name = :perf_test
    event_count = 10_000

    # Record many events
    event_count.times do
      @storage.record_success(circuit_name, 0.01)
    end

    # Counting should be fast (O(bucket_count) not O(event_count))
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count = @storage.success_count(circuit_name, 60)
    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_equal event_count, count
    assert_operator end_time - start_time, :<, 0.01, 'Counting should be very fast'
  end
end
