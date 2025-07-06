# frozen_string_literal: true

require 'breaker_machines'
require 'uri'
require 'net/http'
require 'json'

# Complete example of webhook delivery with dynamic circuit breakers
# Each domain gets its own circuit breaker for independent failure handling
class WebhookDeliveryService
  include BreakerMachines::DSL

  # Define templates for different types of endpoints
  circuit_template :reliable_endpoint do
    threshold failures: 5, within: 2.minutes
    reset_after 1.minute
    timeout 10.seconds

    fallback do |error|
      Rails.logger.error "Reliable endpoint failed: #{error.message}"
      { delivered: false, error: error.message, retry_at: 5.minutes.from_now }
    end
  end

  circuit_template :flaky_endpoint do
    threshold failure_rate: 0.7, minimum_calls: 3, within: 1.minute
    reset_after 30.seconds
    timeout 5.seconds

    fallback do |error|
      Rails.logger.warn "Flaky endpoint failed: #{error.message}"
      { delivered: false, error: error.message, retry_at: 1.minute.from_now }
    end
  end

  circuit_template :critical_endpoint do
    threshold failures: 2, within: 30.seconds
    reset_after 2.minutes
    timeout 15.seconds
    max_concurrent 5 # Limit concurrent requests

    fallback do |error|
      Rails.logger.critical "Critical endpoint failed: #{error.message}"
      AlertService.critical_webhook_failure(error)
      { delivered: false, error: error.message, retry_at: 10.minutes.from_now }
    end
  end

  def initialize
    @delivery_stats = Concurrent::Map.new
  end

  # Deliver webhook with automatic circuit breaker selection
  def deliver_webhook(webhook_url, payload, options = {})
    domain = extract_domain(webhook_url)
    circuit_name = :"webhook_#{domain}"

    # Get or create circuit breaker for this domain
    circuit_breaker = get_or_create_circuit(domain, circuit_name, options)

    result = circuit_breaker.wrap do
      send_webhook(webhook_url, payload, options)
    end

    # Track delivery stats
    update_delivery_stats(domain, result)
    result
  end

  # Bulk delivery with parallel processing and individual circuit protection
  def deliver_bulk_webhooks(webhook_requests)
    results = Concurrent::Array.new
    threads = webhook_requests.map do |request|
      Thread.new do
        result = deliver_webhook(request[:url], request[:payload], request[:options] || {})
        results << { request: request, result: result }
      rescue StandardError => e
        results << { request: request, result: { delivered: false, error: e.message } }
      end
    end

    threads.each(&:join)
    results.to_a
  end

  # Get delivery statistics by domain
  def delivery_stats(domain = nil)
    if domain
      @delivery_stats[domain] || { delivered: 0, failed: 0, circuit_trips: 0 }
    else
      @delivery_stats.to_h
    end
  end

  # Get circuit status for all domains
  def circuit_status
    circuit_instances.transform_values do |circuit|
      {
        state: circuit.state,
        failure_count: circuit.failure_count,
        last_failure: circuit.last_failure_time,
        config: circuit.config.slice(:failure_threshold, :failure_window, :reset_timeout)
      }
    end
  end

  # Force reset circuit for a specific domain (useful for manual recovery)
  def reset_domain_circuit(domain)
    circuit_name = :"webhook_#{domain}"
    circuit_instances[circuit_name]&.reset!
  end

  private

  def extract_domain(url)
    URI.parse(url).host.downcase
  rescue URI::InvalidURIError
    'invalid_domain'
  end

  def get_or_create_circuit(domain, circuit_name, options)
    # Return existing circuit if already created locally
    return circuit_instances[circuit_name] if circuit_instances[circuit_name]

    # Determine template based on domain or options
    template = determine_template(domain, options)

    # Create dynamic circuit with global storage to prevent memory leaks
    # Since webhook services are often long-lived and process many domains
    dynamic_circuit(circuit_name, template: template, global: true) do
      # Custom configuration based on domain characteristics
      if domain.include?('amazonaws.com') || domain.include?('cloudflare.com')
        # AWS/Cloudflare are usually reliable
        threshold failures: 8, within: 3.minutes
        timeout 15.seconds
      elsif domain.include?('herokuapp.com') || domain.include?('ngrok.io')
        # Development/staging endpoints might be flaky
        threshold failure_rate: 0.6, minimum_calls: 5, within: 2.minutes
        timeout 8.seconds
      elsif options[:critical]
        # User marked as critical
        threshold failures: 2, within: 1.minute
        timeout 20.seconds
        max_concurrent 3
      end

      # Add monitoring for all webhook circuits
      on_open do
        Rails.logger.warn "Webhook circuit opened for domain: #{domain}"
        update_circuit_trip_stats(domain)

        # Alert ops team for critical domains
        AlertService.webhook_circuit_open(domain, circuit_name) if options[:critical] || is_critical_domain?(domain)
      end

      on_close do
        Rails.logger.info "Webhook circuit recovered for domain: #{domain}"
        AlertService.webhook_circuit_recovered(domain, circuit_name) if options[:critical]
      end

      # Custom fallback based on domain type
      fallback do |error|
        base_retry_time = calculate_retry_time(domain, error)

        {
          delivered: false,
          error: error.message,
          domain: domain,
          circuit_state: :open,
          retry_at: base_retry_time.from_now
        }
      end
    end
  end

  def determine_template(domain, options)
    return :critical_endpoint if options[:critical] || is_critical_domain?(domain)
    return :reliable_endpoint if is_reliable_domain?(domain)

    :flaky_endpoint # Default for unknown domains
  end

  def is_critical_domain?(domain)
    critical_domains = %w[
      api.stripe.com
      hooks.slack.com
      api.sendgrid.com
      api.twilio.com
    ]
    critical_domains.any? { |critical| domain.include?(critical) }
  end

  def is_reliable_domain?(domain)
    reliable_domains = %w[
      amazonaws.com
      cloudflare.com
      fastly.com
      akamai.com
    ]
    reliable_domains.any? { |reliable| domain.include?(reliable) }
  end

  def calculate_retry_time(domain, error)
    base_time = case error
                when Net::TimeoutError, Timeout::Error
                  5.minutes # Timeout errors might resolve quickly
                when Net::HTTPServerError
                  10.minutes  # Server errors need more time
                else
                  2.minutes   # Default retry time
                end

    # Add domain-specific adjustments
    if is_critical_domain?(domain)
      base_time * 2  # Wait longer for critical services
    elsif domain.include?('ngrok.io') || domain.include?('localhost')
      30.seconds     # Development endpoints recover quickly
    else
      base_time
    end
  end

  def send_webhook(url, payload, options)
    uri = URI.parse(url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = options[:open_timeout] || 5
    http.read_timeout = options[:read_timeout] || 10

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request['User-Agent'] = 'WebhookDeliveryService/1.0'

    # Add custom headers if provided
    options[:headers]&.each { |key, value| request[key] = value }

    request.body = payload.to_json

    response = http.request(request)

    # Consider 2xx responses as successful
    raise Net::HTTPError, "HTTP #{response.code}: #{response.body}" unless response.code.start_with?('2')

    {
      delivered: true,
      status_code: response.code.to_i,
      response_body: response.body,
      delivered_at: Time.current
    }
  end

  def update_delivery_stats(domain, result)
    @delivery_stats.compute(domain) do |_, stats|
      stats ||= { delivered: 0, failed: 0, circuit_trips: 0 }

      if result[:delivered]
        stats[:delivered] += 1
      else
        stats[:failed] += 1
      end

      stats
    end
  end

  def update_circuit_trip_stats(domain)
    @delivery_stats.compute(domain) do |_, stats|
      stats ||= { delivered: 0, failed: 0, circuit_trips: 0 }
      stats[:circuit_trips] += 1
      stats
    end
  end
end

# Example usage and testing
if __FILE__ == $PROGRAM_NAME
  # Stub services for example
  class Rails
    def self.logger
      @logger ||= Logger.new($stdout)
    end
  end

  class AlertService
    def self.critical_webhook_failure(error)
      puts "🚨 CRITICAL: Webhook delivery failed - #{error.message}"
    end

    def self.webhook_circuit_open(domain, circuit_name)
      puts "⚠️  Circuit opened for #{domain} (#{circuit_name})"
    end

    def self.webhook_circuit_recovered(domain, circuit_name)
      puts "✅ Circuit recovered for #{domain} (#{circuit_name})"
    end
  end

  # Example usage
  service = WebhookDeliveryService.new

  # Single webhook delivery
  result = service.deliver_webhook(
    'https://api.example.com/webhook',
    { event: 'user.created', user_id: 123 },
    { critical: true }
  )

  puts "Delivery result: #{result}"

  # Bulk webhook delivery
  webhook_requests = [
    { url: 'https://reliable.amazonaws.com/webhook', payload: { event: 'order.created' } },
    { url: 'https://flaky.herokuapp.com/webhook', payload: { event: 'payment.processed' } },
    { url: 'https://api.stripe.com/webhook', payload: { event: 'invoice.paid' }, options: { critical: true } }
  ]

  results = service.deliver_bulk_webhooks(webhook_requests)
  puts "Bulk delivery results: #{results.size} webhooks processed"

  # Check stats
  puts "Delivery stats: #{service.delivery_stats}"
  puts "Circuit status: #{service.circuit_status}"
end
