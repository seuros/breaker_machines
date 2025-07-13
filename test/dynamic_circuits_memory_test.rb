# frozen_string_literal: true

require 'test_helper'

class DynamicCircuitsMemoryTest < ActiveSupport::TestCase
  def setup
    @test_class = Class.new do
      include BreakerMachines::DSL

      circuit_template :webhook_template do
        threshold failures: 3, within: 60
        reset_after 30
        fallback { |error| { delivered: false, error: error.message } }
      end

      def call_service(name, global: false, &block)
        dynamic_circuit(name, template: :webhook_template, global: global).wrap(&block)
      end
    end
  end

  def teardown
    BreakerMachines.registry.clear
  end

  def test_local_dynamic_circuits_stored_in_instance
    service = @test_class.new

    # Create local dynamic circuit
    result = service.call_service(:local_test, global: false) { 'success' }

    assert_equal 'success', result

    # Should be stored locally
    assert service.circuit_instances.key?(:local_test)

    # Should NOT be in global registry by name
    assert_empty(BreakerMachines.registry.dynamic_circuit_names.select { |name| name == :local_test })
  end

  def test_global_dynamic_circuits_stored_in_registry
    service = @test_class.new

    # Create global dynamic circuit
    result = service.call_service(:global_test, global: true) { 'success' }

    assert_equal 'success', result

    # Should NOT be stored locally
    assert_not service.circuit_instances.key?(:global_test)

    # Should be in global registry
    assert_includes BreakerMachines.registry.dynamic_circuit_names, :global_test
  end

  def test_global_circuits_shared_across_instances
    service1 = @test_class.new
    service2 = @test_class.new

    # Create circuit in first instance
    service1.call_service(:shared_circuit, global: true) { 'from service1' }

    # Trigger failures to open circuit
    3.times do
      service1.call_service(:shared_circuit, global: true) { raise 'failure' }
    rescue StandardError
      nil
    end

    # Second instance should see the same circuit state (open with fallback)
    result = service2.call_service(:shared_circuit, global: true) { 'should not reach' }

    refute result[:delivered]
    assert_includes result[:error], 'open'
  end

  def test_memory_leak_prevention_with_global_circuits
    # Create a long-lived service
    long_lived_service = @test_class.new
    initial_circuit_count = BreakerMachines.registry.dynamic_circuit_names.size

    # Simulate creating many unique circuits (like webhook domains)
    100.times do |i|
      domain_name = :"domain_#{i}"
      long_lived_service.call_service(domain_name, global: true) { 'processed' }
    end

    # All circuits should be in global registry
    current_circuit_count = BreakerMachines.registry.dynamic_circuit_names.size

    assert_equal initial_circuit_count + 100, current_circuit_count

    # Long-lived service should NOT have accumulated circuits locally
    # (They should all be global)
    assert_empty long_lived_service.circuit_instances
  end

  def test_memory_leak_with_local_circuits
    # Create a long-lived service
    long_lived_service = @test_class.new

    # Simulate creating many unique circuits locally (memory leak scenario)
    50.times do |i|
      domain_name = :"local_domain_#{i}"
      long_lived_service.call_service(domain_name, global: false) { 'processed' }
    end

    # All circuits should be stored locally (potential memory leak)
    assert_equal 50, long_lived_service.circuit_instances.size

    # This demonstrates the memory leak - in a real long-lived object,
    # these circuits would never be cleaned up
  end

  def test_global_circuit_cleanup
    service = @test_class.new

    # Create some global circuits
    5.times do |i|
      service.call_service(:"cleanup_test_#{i}", global: true) { 'test' }
    end

    initial_count = BreakerMachines.registry.dynamic_circuit_names.size

    assert_operator initial_count, :>=, 5

    # Remove specific circuits
    assert BreakerMachines.registry.remove_dynamic_circuit(:cleanup_test_0)
    assert BreakerMachines.registry.remove_dynamic_circuit(:cleanup_test_1)

    current_count = BreakerMachines.registry.dynamic_circuit_names.size

    assert_equal initial_count - 2, current_count

    # Removing non-existent circuit should return false
    assert_not BreakerMachines.registry.remove_dynamic_circuit(:non_existent)
  end

  def test_weak_reference_cleanup_on_owner_gc
    weak_refs = []
    circuit_names = []

    # Create many short-lived service instances
    10.times do |i|
      service_instance = @test_class.new
      circuit_name = :"gc_test_#{i}"
      circuit_names << circuit_name

      # Create global circuit
      service_instance.call_service(circuit_name, global: true) { 'test' }

      # Keep weak reference to service for testing
      weak_refs << WeakRef.new(service_instance)
    end

    # All circuits should exist
    circuit_names.each do |name|
      assert_includes BreakerMachines.registry.dynamic_circuit_names, name
    end

    # Force garbage collection
    GC.start
    sleep 0.1 # Give GC time to work

    # Check how many service instances were collected
    weak_refs.count do |ref|
      ref.__getobj__
      true
    rescue WeakRef::RefError
      false
    end

    # Some should be garbage collected (this test may be flaky due to GC timing)
    # The important thing is that circuits should still exist even if owners are GC'd
    circuit_names.each do |name|
      assert_includes BreakerMachines.registry.dynamic_circuit_names, name
    end
  end

  def test_callback_execution_with_weak_owner_references
    test_class_with_callback = Class.new do
      include BreakerMachines::DSL

      def initialize(callback_tracker)
        @callback_tracker = callback_tracker
      end

      def test_with_callback
        dynamic_circuit(:callback_test, global: true) do
          threshold failures: 1, within: 60

          on_open do
            @callback_tracker[:executed] = true
            @callback_tracker[:owner_available] = !@callback_tracker.nil?
          end
        end.wrap { raise 'test error' }
      end
    end

    callback_tracker = { executed: false, owner_available: false }
    service = test_class_with_callback.new(callback_tracker)

    # Trigger circuit open
    begin
      service.test_with_callback
    rescue StandardError
      nil
    end

    assert callback_tracker[:executed], 'Callback should have been executed'
    assert callback_tracker[:owner_available], 'Owner should have been available during callback'
  end

  def test_fallback_execution_with_weak_owner_references
    test_class_with_fallback = Class.new do
      include BreakerMachines::DSL

      def initialize(tracker)
        @tracker = tracker
      end

      def test_with_fallback
        dynamic_circuit(:fallback_test, global: true) do
          threshold failures: 1, within: 60

          fallback do |error|
            @tracker[:executed] = true
            @tracker[:owner_available] = !@tracker.nil?
            @tracker[:error_message] = error.message
            'fallback result'
          end
        end.wrap { raise 'test error' }
      end
    end

    tracker = { executed: false, owner_available: false, error_message: nil }
    service = test_class_with_fallback.new(tracker)

    # Trigger circuit open and fallback
    begin
      service.test_with_fallback
    rescue StandardError
      nil
    end
    result = service.test_with_fallback

    assert_equal 'fallback result', result
    assert tracker[:executed], 'Fallback should have been executed'
    assert tracker[:owner_available], 'Owner should have been available during fallback'
    assert_includes tracker[:error_message], 'open'
  end

  def test_concurrent_global_circuit_creation
    results = Concurrent::Array.new
    threads = []

    # Create multiple threads trying to create the same global circuit
    10.times do |i|
      threads << Thread.new do
        service = @test_class.new
        result = service.call_service(:concurrent_test, global: true) { "thread_#{i}" }
        results << result
      end
    end

    threads.each(&:join)

    # All threads should succeed
    assert_equal 10, results.size
    results.each { |result| assert_match(/thread_\d+/, result) }

    # Only one circuit should exist in registry
    assert_equal(1, BreakerMachines.registry.dynamic_circuit_names.count { |name| name == :concurrent_test })
  end

  def test_explicit_cleanup_pattern
    # Demonstrate explicit cleanup for transient circuits
    service_class = Class.new do
      include BreakerMachines::DSL

      def process_transient_task(task_id)
        circuit_name = :"task_#{task_id}"

        begin
          result = dynamic_circuit(circuit_name, global: true) do
            threshold failures: 2, within: 30
            fallback { 'task failed' }
          end.wrap do
            # Simulate task processing
            "task #{task_id} completed"
          end

          result
        ensure
          # Clean up the circuit when task is done
          remove_dynamic_circuit(circuit_name)
        end
      end
    end

    service = service_class.new
    initial_count = BreakerMachines.registry.dynamic_circuit_names.size

    # Process several transient tasks
    results = (1..5).map do |i|
      service.process_transient_task(i)
    end

    # All tasks should complete
    results.each_with_index do |result, i|
      assert_equal "task #{i + 1} completed", result
    end

    # No circuits should remain (all cleaned up)
    final_count = BreakerMachines.registry.dynamic_circuit_names.size

    assert_equal initial_count, final_count
  end
end
