# frozen_string_literal: true

require 'test_helper'

class StorageStressTest < ActiveSupport::TestCase
  def setup
    BreakerMachines.reset!
  end

  def test_concurrent_writes_100_threads
    storage = BreakerMachines::Storage::Memory.new
    circuit_name = :stress_test
    thread_count = 100
    writes_per_thread = 100

    success_count = Concurrent::AtomicFixnum.new(0)
    failure_count = Concurrent::AtomicFixnum.new(0)

    threads = thread_count.times.map do |i|
      Thread.new do
        writes_per_thread.times do |j|
          if (i + j).even?
            storage.record_success(circuit_name, 0.01)
            success_count.increment
          else
            storage.record_failure(circuit_name, 0.01)
            failure_count.increment
          end
        end
      end
    end

    threads.each(&:join)

    # Verify all writes were recorded
    total_expected = thread_count * writes_per_thread

    assert_equal total_expected, success_count.value + failure_count.value

    # Storage counts should reflect all writes (within window)
    stored_successes = storage.success_count(circuit_name, 60.0)
    stored_failures = storage.failure_count(circuit_name, 60.0)

    assert_equal success_count.value, stored_successes, 'Success count mismatch'
    assert_equal failure_count.value, stored_failures, 'Failure count mismatch'
  end

  def test_memory_bounded_under_sustained_load
    storage = BreakerMachines::Storage::Memory.new(max_events: 1000)
    circuit_name = :memory_bound_test

    # Record many more events than max_events
    5000.times do |i|
      if i.even?
        storage.record_success(circuit_name, 0.001)
      else
        storage.record_failure(circuit_name, 0.001)
      end
    end

    # Event log should be bounded
    event_log = storage.event_log(circuit_name, 2000)

    assert_operator event_log.length, :<=, 1000, "Event log exceeded max_events: #{event_log.length}"
  end

  def test_bucket_storage_concurrent_writes
    storage = BreakerMachines::Storage::BucketMemory.new
    circuit_name = :bucket_stress
    thread_count = 50
    writes_per_thread = 200

    results = Concurrent::Array.new

    threads = thread_count.times.map do |_i|
      Thread.new do
        writes_per_thread.times do
          storage.record_success(circuit_name, 0.01)
          storage.record_failure(circuit_name, 0.01)
        end
        results << :done
      end
    end

    threads.each(&:join)

    assert_equal thread_count, results.length, 'Not all threads completed'

    # Verify storage is in consistent state
    successes = storage.success_count(circuit_name, 60.0)
    failures = storage.failure_count(circuit_name, 60.0)

    expected_per_type = thread_count * writes_per_thread

    assert_equal expected_per_type, successes, 'Success count incorrect'
    assert_equal expected_per_type, failures, 'Failure count incorrect'
  end

  def test_storage_isolation_between_circuits
    storage = BreakerMachines::Storage::Memory.new
    circuits = 10.times.map { |i| :"circuit_#{i}" }

    # Write to all circuits concurrently
    threads = circuits.map do |circuit_name|
      Thread.new do
        100.times do
          storage.record_success(circuit_name, 0.01)
          storage.record_failure(circuit_name, 0.01)
        end
      end
    end

    threads.each(&:join)

    # Verify each circuit has isolated counts
    circuits.each do |circuit_name|
      successes = storage.success_count(circuit_name, 60.0)
      failures = storage.failure_count(circuit_name, 60.0)

      assert_equal 100, successes, "#{circuit_name} success count wrong"
      assert_equal 100, failures, "#{circuit_name} failure count wrong"
    end
  end

  def test_rapid_clear_and_write_race_condition
    storage = BreakerMachines::Storage::Memory.new
    circuit_name = :clear_race

    errors = Concurrent::Array.new

    # Writer threads
    writers = 5.times.map do
      Thread.new do
        100.times do
          storage.record_success(circuit_name, 0.01)
          storage.record_failure(circuit_name, 0.01)
        end
      rescue StandardError => e
        errors << e
      end
    end

    # Clear thread
    clearer = Thread.new do
      50.times do
        storage.clear(circuit_name)
        sleep 0.001
      end
    rescue StandardError => e
      errors << e
    end

    writers.each(&:join)
    clearer.join

    assert_empty errors, "Race condition errors: #{errors.map(&:message).join(', ')}"
  end

  def test_event_ordering_preserved
    storage = BreakerMachines::Storage::Memory.new
    circuit_name = :ordering_test

    # Record events with distinct timestamps
    100.times do |i|
      storage.record_success(circuit_name, i.to_f)
    end

    event_log = storage.event_log(circuit_name, 100)

    # Verify timestamps are in order (oldest first)
    timestamps = event_log.map { |e| e[:timestamp] }
    sorted_timestamps = timestamps.sort

    assert_equal sorted_timestamps, timestamps, 'Events not in chronological order'
  end

  def test_high_frequency_writes_stability
    storage = BreakerMachines::Storage::Memory.new
    circuit_name = :high_freq

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Rapid-fire writes for 1 second
    count = 0
    loop do
      storage.record_success(circuit_name, 0.0001)
      count += 1
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time >= 1.0
    end

    # Verify storage is stable after high-frequency writes
    successes = storage.success_count(circuit_name, 60.0)

    assert_predicate successes, :positive?, "Should have recorded events (got #{successes})"
    assert_operator count, :>=, 1000, "Should achieve at least 1000 writes/sec (got #{count})"
  end
end
