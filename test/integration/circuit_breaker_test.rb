# frozen_string_literal: true

require 'test_helper'

class CircuitBreakerTest < ActionDispatch::IntegrationTest
  def setup
    # Clear all global circuits to prevent test pollution
    BreakerMachines.registry.clear
    
    # Reset all circuits before each test
    post '/test/reset'
  end

  test 'payment succeeds when circuit is closed' do
    get '/test/payment', params: { amount: 50.00 }

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 'success', json['status']
    assert_predicate json['transaction_id'], :present?
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
