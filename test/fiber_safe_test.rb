# frozen_string_literal: true

require 'test_helper'

class FiberSafeTest < ActiveSupport::TestCase
  def setup
    BreakerMachines.config.fiber_safe = true
  end

  def teardown
    BreakerMachines.config.fiber_safe = false
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
    # This test verifies that fiber_safe mode requires async gem context
    # We run this inside an Async block to properly test the behavior

    # Test 1: With async context, fiber_safe works
    Async do
      circuit = BreakerMachines::Circuit.new(:test_with_async_context, fiber_safe: true, timeout: 0.1)
      result = circuit.wrap { 'success' }

      assert_equal 'success', result
    end.wait

    # Test 2: Without async context but with timeout, we expect an error
    circuit_no_context = BreakerMachines::Circuit.new(:test_no_async_context, fiber_safe: true, timeout: 0.1)

    # This should raise an error because we're outside of an Async context
    assert_raises(RuntimeError) do
      circuit_no_context.wrap { 'test' }
    end
  end
end
