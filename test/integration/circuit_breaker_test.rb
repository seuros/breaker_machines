# frozen_string_literal: true

require 'test_helper'

class CircuitBreakerTest < ActionDispatch::IntegrationTest
  def setup
    super
    
    # FIRST: Clear everything to start with a clean slate
    BreakerMachines.registry.clear
    
    # Clear any persisted state in storage backends
    # This ensures circuits start fresh even if they restore from storage
    Rails.cache.clear
    
    # LAST: Call the test reset endpoint to establish baseline state
    # This should be done AFTER all clearing operations
    post '/test/reset'
  end

  def teardown
    super
    # Ensure circuits are cleared after each test
    BreakerMachines.registry.clear
    
    # Clear storage again to prevent state leakage
    Rails.cache.clear
    
    # Reset test behavior
    ExternalApiService.test_payment_behavior = nil
  end

  test 'payment succeeds when circuit is closed and service is healthy' do
    # Force payment to succeed
    ExternalApiService.test_payment_behavior = :success
    
    get '/test/payment', params: { amount: 50.00 }

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 'success', json['status']
    assert_predicate json['transaction_id'], :present?
  ensure
    ExternalApiService.test_payment_behavior = nil
  end

  test 'payment returns fallback when service fails but circuit remains closed' do
    # Force payment to fail
    ExternalApiService.test_payment_behavior = :fail
    
    get '/test/payment', params: { amount: 50.00 }

    assert_response :success
    json = JSON.parse(response.body)

    # Should get fallback response
    assert_equal 'queued', json['status']
    assert_equal 'Payment will be processed when service recovers', json['message']
    assert_predicate json['reference'], :present?
    
    # Verify circuit is still closed (one failure shouldn't trip it)
    service = ExternalApiService.new
    circuit = service.circuit(:payment_gateway)
    assert_equal :closed, circuit.status_name.to_sym
    assert_equal 1, circuit.stats.failure_count
  ensure
    ExternalApiService.test_payment_behavior = nil
  end

  test 'circuit opens after multiple failures and returns fallback' do
    # Force the circuit to trip
    post '/test/trip_payment'

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 'open', json['circuit_state']

    # Now a regular payment request should return fallback
    get '/test/payment', params: { amount: 100.00 }

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 'queued', json['status']
    assert_equal 'Payment will be processed when service recovers', json['message']
    assert_predicate json['reference'], :present?
  end

  test 'weather endpoint returns fallback when circuit is open' do
    # Force failures to open the circuit
    3.times do
      get '/force_failure'
    end

    # Next request should get fallback
    get '/weather'

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 'fallback', json['source']
    assert_equal 'Weather service unavailable', json['error']
    assert json['circuit_open']
  end

  test 'circuit status endpoint shows all circuits' do
    get '/test/status'

    assert_response :success
    json = JSON.parse(response.body)

    assert_predicate json['payment_gateway'], :present?
    assert_predicate json['email_service'], :present?
    assert_includes %w[closed open half_open], json['payment_gateway']['state']
  end

  test 'circuits can be reset via management endpoint' do
    # Trip a circuit first
    post '/test/trip_payment'

    # Reset it
    post '/circuits/payment_gateway/reset'

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 'closed', json['state']
  end

  test 'health check shows circuit status' do
    get '/health'

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 'ok', json['status']
    assert_equal 'all circuits closed', json['services']['circuits']
  end
end
