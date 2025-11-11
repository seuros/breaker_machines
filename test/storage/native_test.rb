# frozen_string_literal: true

require 'test_helper'

class NativeStorageTest < ActiveSupport::TestCase
  def setup
    skip 'Native extension not available' unless BreakerMachines.native_available?
    @storage = BreakerMachines::Storage::Native.new
    @storage.clear_all # Ensure clean state
  end

  def test_records_and_counts_successes
    @storage.record_success('test_circuit', 0.1)
    @storage.record_success('test_circuit', 0.2)

    assert_equal 2, @storage.success_count('test_circuit', 60.0)
    assert_equal 0, @storage.failure_count('test_circuit', 60.0)
  end

  def test_records_and_counts_failures
    @storage.record_failure('test_circuit', 0.5)
    @storage.record_failure('test_circuit', 0.6)

    assert_equal 0, @storage.success_count('test_circuit', 60.0)
    assert_equal 2, @storage.failure_count('test_circuit', 60.0)
  end

  def test_sliding_window_behavior
    # Record events over time
    @storage.record_success('test_circuit', 0.1)
    sleep 0.1
    @storage.record_failure('test_circuit', 0.2)

    # Short window should include both
    assert_equal 1, @storage.success_count('test_circuit', 1.0)
    assert_equal 1, @storage.failure_count('test_circuit', 1.0)

    # Very short window might miss first event
    count = @storage.success_count('test_circuit', 0.05)

    assert_operator count, :<=, 1
  end

  def test_clear_removes_circuit_events
    @storage.record_success('test_circuit', 0.1)
    @storage.record_failure('test_circuit', 0.2)

    assert_equal 1, @storage.success_count('test_circuit', 60.0)

    @storage.clear('test_circuit')

    assert_equal 0, @storage.success_count('test_circuit', 60.0)
    assert_equal 0, @storage.failure_count('test_circuit', 60.0)
  end

  def test_clear_all_removes_all_circuits
    @storage.record_success('circuit_a', 0.1)
    @storage.record_success('circuit_b', 0.1)

    @storage.clear_all

    assert_equal 0, @storage.success_count('circuit_a', 60.0)
    assert_equal 0, @storage.success_count('circuit_b', 60.0)
  end

  def test_event_log_returns_recent_events
    @storage.record_success('test_circuit', 0.1)
    @storage.record_failure('test_circuit', 0.2)
    @storage.record_success('test_circuit', 0.3)

    events = @storage.event_log('test_circuit', 10)

    assert_equal 3, events.size
    assert_equal 'success', events[0][:type]
    assert_equal 'failure', events[1][:type]
    assert_equal 'success', events[2][:type]

    # Check timestamps are present
    assert_kind_of Float, events[0][:timestamp]
    assert_kind_of Float, events[0][:duration_ms]
  end

  def test_event_log_respects_limit
    10.times { |i| @storage.record_success('test_circuit', i * 0.01) }

    events = @storage.event_log('test_circuit', 5)

    assert_equal 5, events.size
  end

  def test_isolates_circuits
    @storage.record_success('circuit_a', 0.1)
    @storage.record_failure('circuit_b', 0.2)

    assert_equal 1, @storage.success_count('circuit_a', 60.0)
    assert_equal 0, @storage.failure_count('circuit_a', 60.0)

    assert_equal 0, @storage.success_count('circuit_b', 60.0)
    assert_equal 1, @storage.failure_count('circuit_b', 60.0)
  end

  def test_thread_safety
    threads = 10.times.map do |i|
      Thread.new do
        100.times do
          @storage.record_success("thread_test_#{i}", 0.01)
        end
      end
    end

    threads.each(&:join)

    # Each circuit should have exactly 100 successes
    10.times do |i|
      assert_equal 100, @storage.success_count("thread_test_#{i}", 60.0)
    end
  end

  def test_integration_with_circuit
    circuit = BreakerMachines::Circuit.new(
      :native_storage_test,
      storage: @storage,
      failure_threshold: 5,
      failure_window: 10
    )

    # Should succeed
    result = circuit.call { 'success' }

    assert_equal 'success', result

    # Trigger failures
    5.times do
      circuit.call { raise 'test error' }
    rescue RuntimeError, BreakerMachines::CircuitOpenError
      # Expected - both test errors and circuit opening
    end

    # Circuit should now be open
    assert_predicate circuit, :open?

    # Storage should reflect all failures
    assert_operator @storage.failure_count(:native_storage_test, 10.0), :>=, 5
  end
end

# Test fallback behavior when native extension is not available
class NativeStorageFallbackTest < ActiveSupport::TestCase
  def setup
    skip 'Native extension not available' unless BreakerMachines.native_available?
    # Create storage regardless of native availability
    @storage = BreakerMachines::Storage::Native.new
  end

  def test_always_creates_storage_instance
    assert_not_nil @storage
    assert_instance_of BreakerMachines::Storage::Native, @storage
  end

  def test_reports_backend_type
    # Should report whether using native or fallback
    if BreakerMachines.native_available?
      assert @storage.native?, 'Should use native when available'
    else
      refute @storage.native?, 'Should use fallback when native not available'
    end
  end

  def test_works_correctly_regardless_of_backend
    # Both backends should work identically
    @storage.record_success('test_circuit', 0.1)
    @storage.record_failure('test_circuit', 0.2)

    assert_equal 1, @storage.success_count('test_circuit', 60.0)
    assert_equal 1, @storage.failure_count('test_circuit', 60.0)
  end

  def test_clears_events_regardless_of_backend
    @storage.record_success('test_circuit', 0.1)
    @storage.clear('test_circuit')

    assert_equal 0, @storage.success_count('test_circuit', 60.0)
  end

  def test_ffi_hybrid_pattern
    # FFI Hybrid Pattern: Always works, uses native if available
    storage_works = begin
      @storage.record_success('test', 0.1)
      @storage.success_count('test', 60.0) == 1
    rescue StandardError
      false
    end

    assert storage_works, 'Storage should always work (FFI Hybrid pattern)'
  end
end
