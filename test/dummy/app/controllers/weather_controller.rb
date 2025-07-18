# frozen_string_literal: true

class WeatherController < ApplicationController
  include BreakerMachines::DSL

  # Test control for deterministic behavior
  cattr_accessor :test_weather_behavior

  def circuit(name)
    case name
    when :weather_api
      dynamic_circuit(:weather_api, global: true) do
        threshold failures: 3, within: 60
        reset_after 30
        timeout 5

        fallback do |_error|
          {
            temperature: 72,
            condition: 'unknown',
            source: 'fallback',
            error: 'Weather service unavailable',
            circuit_open: true
          }
        end
      end
    else
      super
    end
  end

  def show
    weather_data = circuit(:weather_api).wrap do
      fetch_weather_from_external_api
    end

    render json: weather_data
  end

  def force_failure
    # Endpoint to simulate failures for testing
    circuit(:weather_api).wrap do
      raise 'Simulated weather API failure'
    end
  rescue StandardError => e
    render json: {
      error: e.message,
      circuit_state: circuit(:weather_api).status_name,
      failure_count: circuit(:weather_api).failure_count
    }, status: :service_unavailable
  end

  private

  def fetch_weather_from_external_api
    # Simulate an external API call
    if test_weather_behavior
      raise 'Weather API timeout' if test_weather_behavior == :fail
    elsif rand > 0.8
      raise 'Weather API timeout' # 20% chance of failure
    end

    {
      temperature: rand(60..80),
      condition: %w[sunny cloudy rainy].sample,
      source: 'live',
      timestamp: Time.current
    }
  end
end
