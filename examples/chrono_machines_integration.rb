# frozen_string_literal: true

# Example: Combining BreakerMachines with ChronoMachines for retry with circuit breaker
#
# This demonstrates how to use both gems together:
# - ChronoMachines handles retries with exponential backoff
# - BreakerMachines prevents cascading failures by opening the circuit
#
# The pattern: Retry → Circuit Breaker → Service Call
#
# Use cases:
# - API calls that need retry logic with circuit breaker protection
# - Database operations with transient failure handling
# - Distributed system calls with failure isolation

require 'breaker_machines'
require 'chrono_machines'

class ResilientAPIClient
  include BreakerMachines::DSL
  include ChronoMachines::DSL

  # Define circuit breaker
  circuit :api_calls do
    threshold failures: 5, within: 60
    timeout 5
    half_open_requests 2
  end

  # Define retry policy
  chrono_policy :api_retry,
                max_attempts: 3,
                base_delay: 0.1,
                multiplier: 2,
                max_delay: 5,
                jitter_factor: 0.15,
                retryable_exceptions: [Net::HTTPServerError, Timeout::Error]

  def fetch_data(endpoint)
    # Outer layer: Retry with exponential backoff
    with_chrono_policy(:api_retry) do
      # Inner layer: Circuit breaker protection
      circuit(:api_calls).call do
        # Actual service call
        make_http_request(endpoint)
      end
    end
  rescue ChronoMachines::MaxRetriesExceededError => e
    # All retries exhausted
    Rails.logger.error("Failed after all retries: #{e.message}")
    raise
  rescue BreakerMachines::CircuitOpenError => e
    # Circuit is open, fail fast
    Rails.logger.warn("Circuit open, failing fast: #{e.message}")
    raise
  end

  private

  def make_http_request(endpoint)
    # Your HTTP client code here
    # Example with Net::HTTP
    response = Net::HTTP.get_response(URI(endpoint))
    raise Net::HTTPServerError, response.code unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end
end

# Usage example
client = ResilientAPIClient.new

begin
  data = client.fetch_data('https://api.example.com/data')
  puts "Success: #{data}"
rescue StandardError => e
  puts "Failed: #{e.message}"
end

# Alternative: Inline configuration without DSL
def fetch_with_inline_config(url)
  circuit = BreakerMachines::Circuit.new(:inline_api, {
                                           failure_threshold: 3,
                                           reset_timeout: 30
                                         })

  ChronoMachines.retry(max_attempts: 3, base_delay: 0.1) do
    circuit.call do
      Net::HTTP.get_response(URI(url))
    end
  end
end

# Monitoring example with callbacks
class MonitoredAPIClient
  include BreakerMachines::DSL
  include ChronoMachines::DSL

  circuit :monitored_api do
    threshold failures: 5, within: 60

    on_open { |circuit| puts "[ALERT] Circuit #{circuit.name} opened!" }
    on_close { |circuit| puts "[INFO] Circuit #{circuit.name} closed" }
  end

  chrono_policy :monitored_retry,
                max_attempts: 3,
                base_delay: 0.2,
                on_retry: lambda { |ctx|
                            puts "[RETRY] Attempt #{ctx[:attempt]}, waiting #{ctx[:next_delay]}s"
                          },
                on_failure: lambda { |ctx|
                              puts "[FAILURE] Failed after #{ctx[:attempts]} attempts: #{ctx[:exception]}"
                            }

  def call_api(_endpoint)
    with_chrono_policy(:monitored_retry) do
      circuit(:monitored_api).call do
        # API call here
        raise 'Simulated failure' if rand < 0.5 # Demo: 50% failure rate

        { status: 'success' }
      end
    end
  end
end
