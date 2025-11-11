# frozen_string_literal: true

require 'test_helper'

class HedgedExecutionTest < ActiveSupport::TestCase
  def setup
    @call_count = Concurrent::AtomicFixnum.new(0)
    @latencies = Concurrent::Array.new
  end

  def test_hedged_requests_disabled_by_default
    circuit = BreakerMachines::Circuit.new(:test_default)

    result = circuit.wrap do
      @call_count.increment
      'success'
    end

    assert_equal 'success', result
    assert_equal 1, @call_count.value
  end

  def test_single_backend_hedged_requests
    circuit = BreakerMachines::Circuit.new(:test_hedged, {
                                             hedged_requests: true,
                                             hedging_delay: 10,
                                             max_hedged_requests: 2
                                           })

    result = circuit.wrap do
      @call_count.increment
      sleep 0.05 # 50ms
      'delayed result'
    end

    # Should get result from first request that completes
    assert_equal 'delayed result', result
    # May have made 2 requests due to hedging
    assert_operator @call_count.value, :>=, 1
    assert_operator @call_count.value, :<=, 2
  end

  def test_multiple_backends
    fast_backend = lambda {
      sleep 0.01
      'fast'
    }
    slow_backend = lambda {
      sleep 0.1
      'slow'
    }

    circuit = BreakerMachines::Circuit.new(:test_backends, {
                                             backends: [slow_backend, fast_backend],
                                             hedging_delay: 5 # Start second backend after 5ms
                                           })

    start_time = Time.now
    result = circuit.wrap { 'ignored' }
    duration = Time.now - start_time

    # Should get result from fast backend
    assert_equal 'fast', result
    # Should complete quickly (not wait for slow backend)
    assert_operator duration, :<, 0.03
  end

  def test_hedged_request_with_failure
    failing_backend = -> { raise 'Backend error' }
    success_backend = -> { 'success' }

    circuit = BreakerMachines::Circuit.new(:test_hedge_failure, {
                                             backends: [failing_backend, success_backend],
                                             failure_threshold: 3
                                           })

    result = circuit.wrap { 'ignored' }

    assert_equal 'success', result
    assert_predicate circuit, :closed?
  end

  def test_parallel_fallback
    primary = -> { raise 'Primary failed' }
    fallback1 = lambda {
      sleep 0.05
      'fallback1'
    }
    fallback2 = lambda {
      sleep 0.01
      'fallback2'
    }

    circuit = BreakerMachines::Circuit.new(:test_parallel_fallback, {
                                             fallback: BreakerMachines::DSL::ParallelFallbackWrapper.new([fallback1, fallback2])
                                           })

    start_time = Time.now
    result = circuit.wrap(&primary)
    duration = Time.now - start_time

    # Should get fastest fallback
    assert_equal 'fallback2', result
    # Should complete quickly
    assert_operator duration, :<, 0.08
  end

  def test_hedged_with_bulkhead
    circuit = BreakerMachines::Circuit.new(:test_hedged_bulkhead, {
                                             hedged_requests: true,
                                             max_hedged_requests: 3,
                                             hedging_delay: 10,
                                             max_concurrent: 2 # bulkhead limit
                                           })

    results = Concurrent::Array.new
    threads = []
    # Use latches to ensure proper synchronization
    start_latch = Concurrent::CountDownLatch.new(2)
    hold_latch = Concurrent::CountDownLatch.new(1)

    # Start 2 concurrent requests (filling bulkhead)
    2.times do
      threads << Thread.new do
        circuit.wrap do
          start_latch.count_down # Signal we've started
          hold_latch.wait # Wait for signal to complete
          results << 'concurrent'
        end
      end
    end

    # Wait for both threads to be inside the circuit block
    start_latch.wait

    # Now bulkhead should be full - this should be rejected
    assert_raises(BreakerMachines::CircuitBulkheadError) do
      circuit.wrap { 'rejected' }
    end

    # Release the threads
    hold_latch.count_down
    threads.each(&:join)

    assert_equal %w[concurrent concurrent], results.to_a
  end

  def test_dsl_hedged_configuration
    klass = Class.new do
      include BreakerMachines::DSL

      circuit :api do
        threshold failures: 3, within: 60

        hedged do
          delay 100
          max_requests 3
        end

        backends [
          -> { 'backend1' },
          -> { 'backend2' }
        ]
      end
    end

    config = klass.circuit(:api)

    assert config[:hedged_requests]
    assert_equal 100, config[:hedging_delay]
    assert_equal 3, config[:max_hedged_requests]
    assert_equal 2, config[:backends].size
  end

  def test_dsl_parallel_fallback
    klass = Class.new do
      include BreakerMachines::DSL

      circuit :service do
        parallel_fallback [
          -> { 'fallback1' },
          -> { 'fallback2' }
        ]
      end
    end

    config = klass.circuit(:service)

    assert_instance_of BreakerMachines::DSL::ParallelFallbackWrapper, config[:fallback]
    assert_equal 2, config[:fallback].fallbacks.size
  end
end
