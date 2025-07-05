# frozen_string_literal: true

require 'test_helper'

class TestFiberSafe < ActiveSupport::TestCase
  def setup
    skip 'Async gem not available' unless defined?(::Async)

    @original_fiber_safe = BreakerMachines.config.fiber_safe
    BreakerMachines.config.fiber_safe = true
  end

  def teardown
    BreakerMachines.config.fiber_safe = @original_fiber_safe if @original_fiber_safe
  end

  def test_fiber_safe_configuration
    circuit = BreakerMachines::Circuit.new(:test_fiber, fiber_safe: true)

    assert circuit.instance_variable_get(:@config)[:fiber_safe]
  end

  def test_fiber_safe_inherits_from_global_config
    BreakerMachines.config.fiber_safe = true
    circuit = BreakerMachines::Circuit.new(:test_global_fiber)

    assert circuit.instance_variable_get(:@config)[:fiber_safe]
  end

  def test_async_execution_with_timeout
    skip 'Async not loaded' unless defined?(::Async)

    circuit = BreakerMachines::Circuit.new(:test_timeout, {
                                             fiber_safe: true,
                                             timeout: 0.1, # 100ms timeout
                                             failure_threshold: 3
                                           })

    # This should timeout
    Async do
      assert_raises(::Async::TimeoutError) do
        circuit.wrap do
          sleep 0.2 # Sleep longer than timeout
        end
      end
    end.wait
  end

  def test_async_execution_success
    skip 'Async not loaded' unless defined?(::Async)

    circuit = BreakerMachines::Circuit.new(:test_success, {
                                             fiber_safe: true,
                                             failure_threshold: 3
                                           })

    Async do
      result = circuit.wrap { 'success' }

      assert_equal 'success', result
      assert_predicate circuit, :closed?
    end.wait
  end

  def test_async_fallback_execution
    skip 'Async not loaded' unless defined?(::Async)

    circuit = BreakerMachines::Circuit.new(:test_fallback, {
                                             fiber_safe: true,
                                             failure_threshold: 1,
                                             fallback: proc { |error| "fallback: #{error.class}" }
                                           })

    Async do
      # First call fails and opens circuit
      result = circuit.wrap { raise 'boom' }

      assert_equal 'fallback: RuntimeError', result

      # Circuit should be open
      assert_predicate circuit, :open?

      # Next call should get fallback immediately
      result = circuit.wrap { 'never called' }

      assert_equal 'fallback: BreakerMachines::CircuitOpenError', result
    end.wait
  end

  def test_async_callbacks
    skip 'Async not loaded' unless defined?(::Async)

    callback_called = false

    circuit = BreakerMachines::Circuit.new(:test_callbacks, {
                                             fiber_safe: true,
                                             failure_threshold: 1,
                                             on_open: proc { callback_called = true }
                                           })

    Async do
      begin
        circuit.wrap { raise 'trigger open' }
      rescue StandardError
        nil
      end

      assert callback_called
    end.wait
  end

  def test_concurrent_fiber_operations
    skip 'Async not loaded' unless defined?(::Async)

    circuit = BreakerMachines::Circuit.new(:test_concurrent, {
                                             fiber_safe: true,
                                             failure_threshold: 10
                                           })

    success_count = 0
    failure_count = 0

    Async do
      # Run 20 concurrent operations
      tasks = 20.times.map do |i|
        Async do
          circuit.wrap do
            raise 'simulated failure' if (i % 3).zero?

            'success'
          end
          success_count += 1
        rescue StandardError
          failure_count += 1
        end
      end

      # Wait for all tasks
      tasks.each(&:wait)
    end.wait

    assert_equal 13, success_count  # ~2/3 should succeed
    assert_equal 7, failure_count   # ~1/3 should fail
  end

  def test_async_task_fallback
    skip 'Async not loaded' unless defined?(::Async)

    circuit = BreakerMachines::Circuit.new(:test_async_fallback, {
                                             fiber_safe: true,
                                             failure_threshold: 1,
                                             fallback: proc do |_error|
                                               # Return an async task
                                               Async do
                                                 sleep 0.01 # Simulate async work
                                                 'async fallback result'
                                               end
                                             end
                                           })

    Async do
      # Force circuit open
      result = circuit.wrap { raise 'boom' }

      assert_equal 'async fallback result', result
    end.wait
  end

  def test_fiber_safe_mode_requires_async_gem
    # Temporarily undefine Async to test error handling
    if defined?(::Async)
      async_const = ::Async
      Object.send(:remove_const, :Async)
    end

    circuit = BreakerMachines::Circuit.new(:test_no_async, fiber_safe: true)

    assert_raises(LoadError) do
      circuit.wrap { 'test' }
    end
  ensure
    # Restore Async constant if it was removed
    Object.const_set(:Async, async_const) if async_const && !defined?(::Async)
  end
end
