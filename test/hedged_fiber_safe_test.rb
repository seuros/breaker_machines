# frozen_string_literal: true

require 'test_helper'

unless ASYNC_AVAILABLE
  warn "Skipping HedgedFiberSafeTest: async gem not available on #{RUBY_ENGINE}"
  return
end

class HedgedFiberSafeTest < ActiveSupport::TestCase
  def setup
    BreakerMachines.config.fiber_safe = true
  end

  def teardown
    BreakerMachines.config.fiber_safe = false
  end

  def test_fiber_safe_hedged_requests
    circuit = BreakerMachines::Circuit.new(:test_fiber_hedged, {
                                             fiber_safe: true,
                                             hedged_requests: true,
                                             hedging_delay: 10,
                                             max_hedged_requests: 2
                                           })

    Async do
      call_count = 0
      result = circuit.wrap do
        call_count += 1
        sleep(0.02)
        "result-#{call_count}"
      end

      assert_match(/^result-\d+$/, result)
    end.wait
  end

  def test_fiber_safe_multiple_backends
    fast_backend = lambda do
      sleep(0.01)
      'fast'
    end

    slow_backend = lambda do
      sleep(0.1)
      'slow'
    end

    circuit = BreakerMachines::Circuit.new(:test_fiber_backends, {
                                             fiber_safe: true,
                                             backends: [slow_backend, fast_backend],
                                             hedging_delay: 5
                                           })

    Async do
      start_time = Time.now
      result = circuit.wrap { 'ignored' }
      duration = Time.now - start_time

      assert_equal 'fast', result
      assert_operator duration, :<, 0.05
    end.wait
  end

  def test_fiber_safe_parallel_fallback
    primary = -> { raise 'Primary failed' }
    fallback1 = lambda do
      sleep(0.05)
      'fallback1'
    end
    fallback2 = lambda do
      sleep(0.01)
      'fallback2'
    end

    circuit = BreakerMachines::Circuit.new(:test_fiber_parallel_fallback, {
                                             fiber_safe: true,
                                             fallback: BreakerMachines::DSL::ParallelFallbackWrapper.new([fallback1, fallback2])
                                           })

    Async do
      start_time = Time.now
      result = circuit.wrap(&primary)
      duration = Time.now - start_time

      # Should get one of the fallbacks (order may vary due to async nature)
      assert_includes %w[fallback1 fallback2], result
      # Should complete reasonably quickly
      assert_operator duration, :<, 0.1
    end.wait
  end

  def test_concurrent_hedged_requests
    circuit = BreakerMachines::Circuit.new(:test_concurrent_hedged, {
                                             fiber_safe: true,
                                             hedged_requests: true,
                                             max_hedged_requests: 3,
                                             hedging_delay: 5
                                           })

    results = Concurrent::Array.new

    Async do
      tasks = []

      # Launch multiple concurrent hedged requests
      5.times do |i|
        task = Async do
          result = circuit.wrap do
            sleep(0.01 + (i * 0.002))
            "result-#{i}"
          end
          results << result
        end
        tasks << task
      end

      # Wait for all tasks
      tasks.each(&:wait)
    end.wait

    assert_equal 5, results.size
    results.each do |result|
      assert_match(/^result-\d+$/, result)
    end
  end
end
