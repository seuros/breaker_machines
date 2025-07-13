# frozen_string_literal: true

require 'test_helper'

class BulkheadTest < ActiveSupport::TestCase
  def test_max_concurrent_limits_simultaneous_calls
    circuit = BreakerMachines::Circuit.new(:bulkhead_test, {
                                             max_concurrent: 2
                                           })

    # Test that only 2 can run concurrently
    error_raised = false

    # Fill up the 2 slots
    t1 = Thread.new do
      circuit.wrap do
        sleep 0.1
        'thread1'
      end
    end
    t2 = Thread.new do
      circuit.wrap do
        sleep 0.1
        'thread2'
      end
    end

    # Wait a bit to ensure threads are running
    sleep 0.01

    # This should be rejected
    begin
      circuit.wrap { 'thread3' }
    rescue BreakerMachines::CircuitBulkheadError => e
      error_raised = true

      assert_equal 2, e.max_concurrent
    end

    assert error_raised, 'Expected CircuitBulkheadError to be raised'

    # Wait for threads to complete
    t1.join
    t2.join

    # Now we should be able to run again
    result = circuit.wrap { 'thread4' }

    assert_equal 'thread4', result
  end

  def test_bulkhead_with_fallback
    circuit = BreakerMachines::Circuit.new(:bulkhead_fallback, {
                                             max_concurrent: 1,
                                             fallback: ->(_error) { 'fallback_value' }
                                           })

    results = Concurrent::Array.new

    # Start 2 threads
    threads = 2.times.map do |i|
      Thread.new do
        result = circuit.wrap do
          sleep 0.1
          "thread_#{i}"
        end
        results << result
      end
    end

    threads.each(&:join)

    # One gets real value, one gets fallback
    assert_equal 2, results.size
    assert results.include?('thread_0') || results.include?('thread_1')
    assert_includes results, 'fallback_value'
  end

  def test_bulkhead_releases_permits_after_completion
    circuit = BreakerMachines::Circuit.new(:bulkhead_release, {
                                             max_concurrent: 1
                                           })

    # First call should succeed
    result1 = circuit.wrap { 'first' }

    assert_equal 'first', result1

    # Second call should also succeed (permit was released)
    result2 = circuit.wrap { 'second' }

    assert_equal 'second', result2
  end

  def test_bulkhead_releases_permits_on_error
    circuit = BreakerMachines::Circuit.new(:bulkhead_error, {
                                             max_concurrent: 1,
                                             failure_threshold: 10 # High threshold so circuit doesn't open
                                           })

    # First call fails but releases permit
    assert_raises(RuntimeError) do
      circuit.wrap { raise 'error' }
    end

    # Second call should succeed (permit was released)
    result = circuit.wrap { 'success' }

    assert_equal 'success', result
  end

  def test_circuit_without_bulkhead_works_normally
    circuit = BreakerMachines::Circuit.new(:no_bulkhead, {})

    # Many concurrent calls should all succeed
    results = Concurrent::Array.new

    threads = 10.times.map do |i|
      Thread.new do
        result = circuit.wrap { "thread_#{i}" }
        results << result
      end
    end

    threads.each(&:join)

    # All 10 should succeed
    assert_equal 10, results.size
  end
end
