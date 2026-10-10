# frozen_string_literal: true

require 'test_helper'

class HedgedExecutionTest < ActiveSupport::TestCase
  # How long a deliberately slow branch can block. Tests assert only that they
  # finish well inside it, so scheduler noise cannot fail them.
  SLOW_BRANCH_SECS = 5.0

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
    # The slow backend cannot finish before `wrap` returns: it waits for a
    # release that only comes afterwards (or for SLOW_BRANCH_SECS).
    release_slow = Concurrent::Event.new
    fast_backend = -> { 'fast' }
    slow_backend = lambda {
      release_slow.wait(SLOW_BRANCH_SECS)
      'slow'
    }

    circuit = BreakerMachines::Circuit.new(:test_backends, {
                                             backends: [slow_backend, fast_backend],
                                             hedging_delay: 5 # Start second backend after 5ms
                                           })

    result, duration = timed { circuit.wrap { 'ignored' } }
    release_slow.set

    # Should get result from fast backend
    assert_equal 'fast', result
    # Returned without waiting for the slow backend
    assert_operator duration, :<, SLOW_BRANCH_SECS / 2
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
    # fallback1 (listed first) finishes only after fallback2's thread has
    # queued its result, so the winner is decided by completion order rather
    # than by sleeps. Run one after the other, fallback1 would instead wait out
    # SLOW_BRANCH_SECS and win by list order.
    fast_thread = Concurrent::IVar.new
    fallback1 = lambda {
      fast_thread.value(SLOW_BRANCH_SECS)&.join
      'fallback1'
    }
    fallback2 = lambda {
      fast_thread.set(Thread.current)
      'fallback2'
    }

    circuit = BreakerMachines::Circuit.new(:test_parallel_fallback, {
                                             fallback: BreakerMachines::DSL::ParallelFallbackWrapper.new([fallback1, fallback2])
                                           })

    result, duration = timed { circuit.wrap(&primary) }

    # Should get the fallback that finished first
    assert_equal 'fallback2', result
    # The fallbacks ran in parallel: nothing waited out the slow branch
    assert_operator duration, :<, SLOW_BRANCH_SECS / 2
  end

  def test_hedged_with_bulkhead
    circuit = BreakerMachines::Circuit.new(:test_hedged_bulkhead, {
                                             hedged_requests: true,
                                             max_hedged_requests: 3,
                                             hedging_delay: 10,
                                             max_concurrent: 2 # bulkhead limit
                                           })

    # Count wraps, not attempts: hedging runs extra copies of a block that is
    # still blocked after `hedging_delay`, and those copies share `entered`.
    start_latch = Concurrent::CountDownLatch.new(2)
    hold_latch = Concurrent::CountDownLatch.new(1)

    # Start 2 concurrent requests (filling bulkhead)
    threads = Array.new(2) do
      Thread.new do
        entered = Concurrent::AtomicBoolean.new(false)
        circuit.wrap do
          start_latch.count_down if entered.make_true # Signal this wrap started
          hold_latch.wait # Wait for signal to complete
          'concurrent'
        end
      end
    end

    # Wait for both wraps to be inside the circuit, each holding a permit
    assert start_latch.wait(SLOW_BRANCH_SECS), 'both wraps should enter the circuit'

    # Now bulkhead should be full - this should be rejected
    assert_raises(BreakerMachines::CircuitBulkheadError) do
      circuit.wrap { 'rejected' }
    end

    # Release the threads; each wrap returns its block's result once
    hold_latch.count_down

    assert_equal %w[concurrent concurrent], threads.map(&:value)
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

  private

  # The block's result and how long it took, in seconds.
  def timed
    start_time = BreakerMachines.monotonic_time
    result = yield
    [result, BreakerMachines.monotonic_time - start_time]
  end
end
