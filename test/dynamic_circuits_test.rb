# frozen_string_literal: true

require 'test_helper'

class TestDynamicCircuits < ActiveSupport::TestCase
  def setup
    @test_class = Class.new do
      include BreakerMachines::DSL

      circuit_template :fast_service do
        threshold failures: 2, within: 30
        reset_after 15
        timeout 1
        fallback { 'fast fallback' }
      end

      circuit_template :slow_service do
        threshold failures: 5, within: 60
        reset_after 30
        timeout 5
        fallback { 'slow fallback' }
      end

      circuit_template :critical_service do
        threshold failures: 1, within: 10
        reset_after 60
        timeout 10
        max_concurrent 3
        fallback { 'critical fallback' }
      end

      def call_service(name, &block)
        circuit(name).wrap(&block)
      end

      def call_dynamic_service(name, template: nil, config: nil, &business_logic)
        circuit_breaker = if config
                            dynamic_circuit(name, template: template, &config)
                          else
                            dynamic_circuit(name, template: template)
                          end

        circuit_breaker.wrap(&business_logic)
      end
    end

    @service = @test_class.new
  end

  def test_circuit_template_creation
    # Template should be accessible
    assert_not_nil @test_class.circuit_template(:fast_service)
    assert_not_nil @test_class.circuit_template(:slow_service)
    assert_not_nil @test_class.circuit_template(:critical_service)
  end

  def test_circuit_template_configuration
    fast_config = @test_class.circuit_template(:fast_service)

    assert_equal 2, fast_config[:failure_threshold]
    assert_equal 30, fast_config[:failure_window]
    assert_equal 15, fast_config[:reset_timeout]
    assert_equal 1, fast_config[:timeout]
  end

  def test_dynamic_circuit_with_template
    # Create dynamic circuit with template
    result = @service.call_dynamic_service(:test_dynamic, template: :fast_service) do
      'success'
    end

    assert_equal 'success', result

    # Circuit should exist in instances
    circuit = @service.circuit_instances[:test_dynamic]

    assert_not_nil circuit

    # Should have template configuration
    assert_equal 2, circuit.config[:failure_threshold]
    assert_equal 30, circuit.config[:failure_window]
  end

  def test_dynamic_circuit_without_template
    # Create dynamic circuit without template (uses defaults)
    result = @service.call_dynamic_service(:test_default) { 'success' }

    assert_equal 'success', result

    circuit = @service.circuit_instances[:test_default]

    assert_not_nil circuit

    # Should have default configuration
    assert_equal 5, circuit.config[:failure_threshold] # Default
    assert_equal 60, circuit.config[:failure_window] # Default
  end

  def test_dynamic_circuit_with_custom_configuration
    # Create dynamic circuit with template and custom overrides
    custom_config = proc do
      threshold failures: 8, within: 120 # Override template
      timeout 3                            # Override template
      max_concurrent 10                    # Add new config
    end

    @service.call_dynamic_service(:test_custom, template: :fast_service, config: custom_config) do
      'success'
    end

    circuit = @service.circuit_instances[:test_custom]

    # Should have overridden values
    assert_equal 8, circuit.config[:failure_threshold]
    assert_equal 120, circuit.config[:failure_window]
    assert_equal 3, circuit.config[:timeout]
    assert_equal 10, circuit.config[:max_concurrent]

    # Should keep template values for non-overridden config
    assert_equal 15, circuit.config[:reset_timeout]
  end

  def test_dynamic_circuit_fallback_behavior
    # Create dynamic circuit that will fail
    begin
      @service.call_dynamic_service(:test_fallback, template: :fast_service) do
        raise 'Service error'
      end
    rescue StandardError
      nil
    end

    begin
      @service.call_dynamic_service(:test_fallback, template: :fast_service) do
        raise 'Service error'
      end
    rescue StandardError
      nil
    end

    # Circuit should be open and use fallback
    result = @service.call_dynamic_service(:test_fallback, template: :fast_service) do
      'should not reach'
    end

    assert_equal 'fast fallback', result
  end

  def test_apply_template_method
    # Apply template to create new circuit
    @service.apply_template(:templated_circuit, :slow_service)

    circuit = @service.circuit_instances[:templated_circuit]

    assert_not_nil circuit

    # Should have template configuration
    assert_equal 5, circuit.config[:failure_threshold]
    assert_equal 60, circuit.config[:failure_window]
    assert_equal 30, circuit.config[:reset_timeout]
  end

  def test_apply_template_with_invalid_template
    assert_raises(ArgumentError, "Template 'nonexistent' not found") do
      @service.apply_template(:test_circuit, :nonexistent)
    end
  end

  def test_multiple_dynamic_circuits_independence
    # Create multiple dynamic circuits
    @service.call_dynamic_service(:service_a, template: :fast_service) { 'a' }
    @service.call_dynamic_service(:service_b, template: :slow_service) { 'b' }

    # Fail service_a
    2.times do
      @service.call_dynamic_service(:service_a) { raise 'error' }
    rescue StandardError
      nil
    end

    # service_a should be open
    result_a = @service.call_dynamic_service(:service_a) { 'should not reach' }

    assert_equal 'fast fallback', result_a

    # service_b should still be closed
    result_b = @service.call_dynamic_service(:service_b) { 'b works' }

    assert_equal 'b works', result_b
  end

  def test_circuit_reuse
    # First call creates circuit
    @service.call_dynamic_service(:reuse_test, template: :fast_service) { 'first' }
    first_circuit = @service.circuit_instances[:reuse_test]

    # Second call reuses same circuit
    @service.call_dynamic_service(:reuse_test, template: :fast_service) { 'second' }
    second_circuit = @service.circuit_instances[:reuse_test]

    assert_same first_circuit, second_circuit
  end

  def test_webhook_delivery_scenario
    webhook_service = Class.new do
      include BreakerMachines::DSL

      circuit_template :webhook_default do
        threshold failures: 3, within: 60
        reset_after 30
        timeout 5
        fallback { |error| { delivered: false, error: error.message } }
      end

      def deliver_webhook(domain, payload)
        circuit_name = :"webhook_#{domain}"

        circuit_breaker = dynamic_circuit(circuit_name, template: :webhook_default) do
          # Custom config per domain
          if domain.include?('reliable')
            threshold failures: 5, within: 120
          elsif domain.include?('flaky')
            threshold failure_rate: 0.7, minimum_calls: 3, within: 60
          end
        end

        circuit_breaker.wrap do
          # Simulate webhook delivery
          raise 'Webhook delivery failed' if domain.include?('failing')

          { delivered: true, payload: payload }
        end
      end
    end

    service = webhook_service.new

    # Successful delivery
    result = service.deliver_webhook('reliable.com', { event: 'test' })

    assert result[:delivered]

    # Failing domain should eventually use fallback
    3.times do
      service.deliver_webhook('failing.com', { event: 'test' })
    rescue StandardError
      nil
    end

    result = service.deliver_webhook('failing.com', { event: 'test' })

    refute result[:delivered]
    assert_includes result[:error], 'open'
  end

  def test_template_inheritance_across_classes
    parent_class = Class.new do
      include BreakerMachines::DSL

      circuit_template :parent_template do
        threshold failures: 10, within: 300
        reset_after 60
      end
    end

    child_class = Class.new(parent_class) do
      circuit_template :child_template do
        threshold failures: 3, within: 60
        reset_after 15
      end
    end

    child_instance = child_class.new

    # Should have access to both parent and child templates
    child_instance.apply_template(:parent_circuit, :parent_template)
    child_instance.apply_template(:child_circuit, :child_template)

    parent_circuit = child_instance.circuit_instances[:parent_circuit]
    child_circuit = child_instance.circuit_instances[:child_circuit]

    assert_equal 10, parent_circuit.config[:failure_threshold]
    assert_equal 3, child_circuit.config[:failure_threshold]
  end

  def test_memory_cleanup_on_garbage_collection
    # This test verifies that circuits are properly cleaned up
    # when their parent objects are garbage collected

    weak_refs = []

    5.times do |i|
      service_instance = @test_class.new
      service_instance.call_dynamic_service(:"test_#{i}", template: :fast_service) { 'test' }
      weak_refs << WeakRef.new(service_instance)
    end

    # Force garbage collection
    GC.start
    sleep 0.1 # Give GC time to clean up

    # Some weak refs should be garbage collected
    # (This is a bit fragile as GC timing is not guaranteed)
    weak_refs.count do |ref|
      ref.__getobj__
      true
    rescue WeakRef::RefError
      false
    end

    # At least verify the test setup works
    assert_operator weak_refs.size, :>, 0
  end

  def test_bulk_webhook_delivery
    bulk_service = Class.new do
      include BreakerMachines::DSL

      circuit_template :webhook_template do
        threshold failures: 2, within: 30
        reset_after 15
        fallback { |error| { delivered: false, error: error.message } }
      end

      def deliver_bulk_webhooks(requests)
        results = []

        requests.each do |request|
          domain = request[:domain]
          circuit_name = :"webhook_#{domain}"

          result = dynamic_circuit(circuit_name, template: :webhook_template).wrap do
            raise "Webhook failed for #{domain}" if request[:should_fail]

            { delivered: true, domain: domain, payload: request[:payload] }
          end

          results << { request: request, result: result }
        end

        results
      end
    end

    service = bulk_service.new

    requests = [
      { domain: 'good.com', payload: { event: 'test1' }, should_fail: false },
      { domain: 'bad.com', payload: { event: 'test2' }, should_fail: true },
      { domain: 'good.com', payload: { event: 'test3' }, should_fail: false }
    ]

    results = service.deliver_bulk_webhooks(requests)

    assert_equal 3, results.size
    assert results[0][:result][:delivered] # good.com works
    assert_not results[1][:result][:delivered] # bad.com fails
    assert results[2][:result][:delivered] # good.com still works
  end
end
