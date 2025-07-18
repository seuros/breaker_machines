# frozen_string_literal: true

require 'test_helper'

class WeatherControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Clear all global circuits to prevent test pollution
    BreakerMachines.registry.clear

    # Reset all circuits before each test
    BreakerMachines.registry.all_circuits.each do |circuit|
      circuit.reset! if circuit.open? || circuit.half_open?
    end

    # Ensure deterministic behavior
    WeatherController.test_weather_behavior = :success
  end

  def teardown
    super
    # Reset test behavior
    WeatherController.test_weather_behavior = nil
  end

  test 'returns weather data when circuit is closed' do
    get '/weather'

    assert_response :success

    json = JSON.parse(response.body)

    assert_predicate json['temperature'], :present?
    assert_predicate json['condition'], :present?
    assert_equal 'live', json['source']
  end

  test 'returns fallback data when circuit is open' do
    # Force failures to open the circuit
    WeatherController.test_weather_behavior = :fail
    3.times do
      get '/weather'
    end

    # Reset behavior so next call doesn't fail
    WeatherController.test_weather_behavior = :success

    # Now the circuit should be open
    get '/weather'

    assert_response :success

    json = JSON.parse(response.body)

    assert_equal 72, json['temperature']
    assert_equal 'unknown', json['condition']
    assert_equal 'fallback', json['source']
    assert json['circuit_open']
    assert_equal 'Weather service unavailable', json['error']
  end

  test 'circuit opens after threshold failures' do
    # Check initial state
    get '/circuits'
    json = JSON.parse(response.body)
    weather_circuit = json['circuits'].find { |c| c['name'] == 'weather_api' }

    # Skip test if weather circuit doesn't exist yet
    skip 'Weather circuit not found' unless weather_circuit

    assert_equal 'closed', weather_circuit['state']

    # Trigger failures
    WeatherController.test_weather_behavior = :fail
    3.times do |_i|
      get '/weather'
      # The circuit will return fallback after 3 failures
    end

    # Check circuit is now open
    get '/circuits'
    json = JSON.parse(response.body)
    weather_circuit = json['circuits'].find { |c| c['name'] == 'weather_api' }

    assert_equal 'open', weather_circuit['state']
  end

  test 'can reset circuit manually' do
    # Open the circuit
    WeatherController.test_weather_behavior = :fail
    3.times { get '/weather' }

    # Reset it
    post '/circuits/weather_api/reset'

    assert_response :success

    reset_json = JSON.parse(response.body)

    assert_equal 'closed', reset_json['state']

    # Reset behavior to success and verify it's working again
    WeatherController.test_weather_behavior = :success
    get '/weather'
    json = JSON.parse(response.body)

    assert_equal 'live', json['source']
  end
end
