# frozen_string_literal: true

require 'test_helper'

# Only run async tests if async gem is available
begin
  require 'async'

  class AsyncCircuitTest < Minitest::Test
    def setup
      BreakerMachines.reset!
      @storage = BreakerMachines::Storage::Memory.new
      BreakerMachines.default_storage = @storage
    end

    def test_async_circuit_basic_functionality
      circuit = BreakerMachines::AsyncCircuit.new('async_api', {
                                                    failure_threshold: 2,
                                                    reset_timeout: 0.1
                                                  })

      # Should start closed
      assert_equal :closed, circuit.status_name

      # Successful async call
      Async do
        result = circuit.call_async { 'Success!' }.wait

        assert_equal 'Success!', result
      end

      # Trip the circuit with failures
      2.times do
        assert_raises(StandardError) do
          circuit.call { raise 'API Error' }
        end
      end

      assert_equal :open, circuit.status_name
    end

    def test_async_state_transitions
      circuit = BreakerMachines::AsyncCircuit.new('async_service', {
                                                    failure_threshold: 1
                                                  })

      # Test async event firing
      Async do
        # Force open asynchronously
        task = circuit.fire_async(:force_open)
        task.wait if task.respond_to?(:wait)

        assert_predicate circuit, :open?

        # Force close asynchronously
        task = circuit.fire_async(:force_close)
        task.wait if task.respond_to?(:wait)

        assert_predicate circuit, :closed?
      end
    end

    def test_concurrent_circuit_operations
      circuit = BreakerMachines::AsyncCircuit.new('concurrent_api', {
                                                    failure_threshold: 10,
                                                    timeout: 0.1
                                                  })

      # Run multiple concurrent operations
      Async do
        tasks = 10.times.map do |i|
          Async do
            circuit.call_async { "Task #{i}" }.wait
          end
        end

        results = tasks.map(&:wait)

        assert_equal 10, results.size
        results.each_with_index do |result, i|
          assert_equal "Task #{i}", result
        end
      end

      # Circuit should still be closed after successful calls
      assert_predicate circuit, :closed?
    end

    def test_async_health_check
      circuit = BreakerMachines::AsyncCircuit.new('health_check_api', {
                                                    failure_threshold: 2
                                                  })

      Async do
        health = circuit.health_check_async.wait

        assert_equal 'health_check_api', health[:name]
        assert_equal :closed, health[:status]
        refute health[:open]
        refute health[:can_recover]
      end

      # Trip the circuit
      2.times do
        assert_raises(StandardError) do
          circuit.call { raise 'Error' }
        end
      end

      Async do
        health = circuit.health_check_async.wait

        assert_equal :open, health[:status]
        assert health[:open]
      end
    end

    def test_async_circuit_with_fallback
      circuit = BreakerMachines::AsyncCircuit.new('fallback_api', {
                                                    failure_threshold: 1,
                                                    fallback: ->(error) { "Fallback: #{error.message}" }
                                                  })

      # Trip the circuit
      result = circuit.call { raise 'Service unavailable' }

      assert_equal 'Fallback: Service unavailable', result

      # Async call should also use fallback when open
      Async do
        result = circuit.call_async { raise 'Still unavailable' }.wait

        assert_equal "Fallback: Circuit 'fallback_api' is open", result
      end
    end
  end
rescue LoadError
  # Skip async tests if async gem is not available
  puts 'Skipping AsyncCircuitTest - async gem not available'
end
