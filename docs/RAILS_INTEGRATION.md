# Rails Integration

## Installation

For general installation instructions, refer to the [Getting Started Guide](GETTING_STARTED.md).

Add to your Gemfile:

```ruby
gem 'breaker_machines'
```

Run bundle install and create an initializer:

```ruby
# config/initializers/breaker_machines.rb
BreakerMachines.configure do |config|
  config.default_storage = Rails.env.test? ? :memory : :cache
  config.log_events = !Rails.env.test?
  config.default_reset_timeout = 60.seconds
  config.default_failure_threshold = 5
  
  # Enable fiber_safe mode if using Falcon
  config.fiber_safe = defined?(Falcon)
end

# Set up ActiveSupport::Notifications integration. For more details on observability, see the [Observability Guide](OBSERVABILITY.md).
ActiveSupport::Notifications.subscribe(/^breaker_machines\./) do |name, start, finish, id, payload|
  event_type = name.split('.').last
  circuit_name = payload[:circuit]
  
  Rails.logger.tagged('CircuitBreaker', circuit_name) do
    case event_type
    when 'opened'
      Rails.logger.error "Circuit opened - rejecting requests"
    when 'closed'
      Rails.logger.info "Circuit recovered - accepting requests"
    when 'half_opened'
      Rails.logger.info "Circuit testing recovery"
    end
  end
end
```

## Controller Integration

### Base Controller Setup

```ruby
class ApplicationController < ActionController::Base
  include BreakerMachines::DSL

  circuit :auth_service do
    threshold failures: 3, within: 60
    reset_after 30

    fallback do
      # Allow access with limited permissions
      GuestUser.new
    end
  end

  circuit :rate_limiter do
    threshold failures: 5, within: 10
    reset_after 60

    fallback do
      # Just let them through - better than 500 errors
      { allowed: true, limited: true }
    end
  end

  before_action :authenticate_with_breaker

  private

  def authenticate_with_breaker
    @current_user = circuit(:auth_service).wrap do
      AuthService.authenticate(session[:token])
    end
  end

  def check_rate_limit
    result = circuit(:rate_limiter).wrap do
      RateLimiter.check(request.remote_ip)
    end

    if result[:limited]
      response.headers['X-RateLimit-Degraded'] = 'true'
    end
  end
end
```

### API Controller Example

```ruby
class Api::V1::BaseController < ApplicationController
  include BreakerMachines::DSL

  circuit :api_gateway do
    threshold failure_rate: 0.5, minimum_calls: 10, within: 1.minute
    reset_after 30.seconds
    
    fallback do |error|
      render json: {
        error: "Service temporarily unavailable",
        retry_after: 30,
        request_id: request.request_id
      }, status: :service_unavailable
    end
  end

  around_action :wrap_in_circuit

  private

  def wrap_in_circuit
    circuit(:api_gateway).wrap { yield }
  rescue BreakerMachines::CircuitOpenError => e
    # Fallback already rendered, just ensure we don't double-render
    return
  end
end
```

## Model Integration

### ActiveRecord Protection

```ruby
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  include BreakerMachines::DSL

  class << self
    circuit :database_read do
      threshold failures: 3, within: 30
      reset_after 45

      fallback do
        # Return cached version or empty set
        Rails.cache.fetch("#{table_name}:fallback:#{caller_locations(1,1)[0]}")
      end
    end

    circuit :database_write do
      threshold failures: 2, within: 30
      reset_after 60

      fallback do |error|
        # Queue for later processing
        DatabaseWriteJob.perform_later(
          table: table_name,
          operation: 'save',
          data: error.is_a?(Hash) ? error : {}
        )
        OpenStruct.new(id: SecureRandom.uuid, persisted?: false)
      end
    end

    # Wrap dangerous queries
    def with_circuit(&block)
      circuit(:database_read).wrap(&block)
    end
  end

  # Protect saves with circuit breaker
  def save_with_circuit(*args)
    self.class.circuit(:database_write).wrap do
      save_without_circuit(*args)
    end
  rescue BreakerMachines::CircuitOpenError => e
    # Circuit is open, queue for later
    DatabaseWriteJob.perform_later(
      model_name: self.class.name,
      attributes: attributes,
      operation: 'save'
    )
    # Return a response that looks like a successful save
    OpenStruct.new(id: id || SecureRandom.uuid, persisted?: false)
  end

  alias_method :save_without_circuit, :save
  alias_method :save, :save_with_circuit
end
```

### Service Object Pattern

```ruby
class PaymentProcessor
  include BreakerMachines::DSL

  circuit :stripe do
    threshold failures: 3, within: 1.minute
    reset_after 30.seconds
    storage :cache  # Share state across workers
    
    fallback do |error|
      # Queue for retry
      PaymentRetryJob.perform_later(payment_id: @payment_id)
      
      Payment.new(
        status: 'pending',
        queued_at: Time.current,
        error_message: "Payment processing delayed"
      )
    end
  end

  circuit :fraud_check do
    threshold failures: 5, within: 2.minutes
    reset_after 1.minute
    
    fallback do
      # Allow with manual review flag
      { risk_score: 'unknown', require_review: true }
    end
  end

  def process(payment_id)
    @payment_id = payment_id
    payment = Payment.find(payment_id)
    
    # Check fraud first
    fraud_result = circuit(:fraud_check).wrap do
      FraudService.check(payment)
    end
    
    if fraud_result[:risk_score] == 'high'
      payment.reject!("High fraud risk")
      return payment
    end
    
    # Process payment
    circuit(:stripe).wrap do
      Stripe::Charge.create(
        amount: payment.amount_cents,
        currency: payment.currency,
        source: payment.source_token,
        metadata: {
          payment_id: payment.id,
          fraud_check: fraud_result[:risk_score]
        }
      )
    end
    
    payment.complete!
    payment
  end
end
```

## Job Integration

### ActiveJob Protection

```ruby
class ApplicationJob < ActiveJob::Base
  include BreakerMachines::DSL

  circuit :job_infrastructure do
    threshold failures: 5, within: 5.minutes
    reset_after 2.minutes
    storage :cache  # Important for distributed job processing. See [Persistence Options](PERSISTENCE.md) for more details on storage backends.
    
    fallback do
      # Re-enqueue the job
      retry_job wait: 5.minutes
    end
  end

  around_perform do |job, block|
    circuit(:job_infrastructure).wrap(&block)
  rescue BreakerMachines::CircuitOpenError
    # Fallback already handled re-enqueueing
    Rails.logger.warn "Job #{job.class} skipped due to open circuit"
  end
end
```

### Sidekiq Integration

```ruby
# config/initializers/sidekiq.rb
require 'breaker_machines'

class SidekiqCircuitMiddleware
  include BreakerMachines::DSL

  circuit :redis_commands do
    threshold failures: 10, within: 30.seconds
    reset_after 1.minute
    storage :memory  # Don't use Redis for Redis circuit!
    
    fallback do
      # Log and skip
      Rails.logger.error "Redis circuit open - job skipped"
      nil
    end
  end

  def call(worker, job, queue)
    circuit(:redis_commands).wrap { yield }
  rescue BreakerMachines::CircuitOpenError
    # Re-enqueue for later
    worker.class.perform_in(5.minutes, *job['args'])
    nil
  end
end

Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add SidekiqCircuitMiddleware
  end
end
```

## Caching Integration

```ruby
class SmartCacheStore
  include BreakerMachines::DSL

  circuit :cache_backend do
    threshold failures: 5, within: 30.seconds
    reset_after 45.seconds
    
    fallback do |error|
      # Return nil on read, silently fail on write
      if error.message.include?('read')
        nil
      else
        Rails.logger.warn "Cache write failed, circuit open"
        false
      end
    end
  end

  def read(key)
    circuit(:cache_backend).wrap do
      Rails.cache.read(key)
    end
  end

  def write(key, value, options = {})
    circuit(:cache_backend).wrap do
      Rails.cache.write(key, value, options)
    end
  end

  def fetch(key, options = {}, &block)
    cached = read(key)
    return cached if cached.present?
    
    value = block.call
    write(key, value, options)
    value
  end
end

# Use in Rails
Rails.application.config.smart_cache = SmartCacheStore.new
```

## ActionCable Integration

```ruby
class ApplicationCable::Connection < ActionCable::Connection::Base
  include BreakerMachines::DSL
  identified_by :current_user

  circuit :websocket_auth do
    threshold failures: 5, within: 60
    reset_after 120

    fallback do
      # Reject connection safely
      reject_unauthorized_connection
    end
  end

  def connect
    self.current_user = circuit(:websocket_auth).wrap do
      find_verified_user
    end
  end

  private

  def find_verified_user
    if verified_user = User.find_by(id: cookies.encrypted[:user_id])
      verified_user
    else
      raise "Unauthorized"
    end
  end
end

class ApplicationCable::Channel < ActionCable::Channel::Base
  include BreakerMachines::DSL

  circuit :broadcast do
    threshold failures: 10, within: 1.minute
    reset_after 30.seconds
    
    fallback do |error|
      # Log but don't crash the connection
      Rails.logger.error "Broadcast failed: #{error.message}"
      notify_user_of_degradation
    end
  end

  def broadcast_with_circuit(data)
    circuit(:broadcast).wrap do
      ActionCable.server.broadcast(channel_name, data)
    end
  end
  
  private
  
  def notify_user_of_degradation
    transmit(type: 'degraded', message: 'Some features may be delayed')
  end
end
```

## Mailer Protection

```ruby
class ApplicationMailer < ActionMailer::Base
  include BreakerMachines::DSL

  circuit :email_service do
    threshold failures: 3, within: 5.minutes
    reset_after 10.minutes
    
    fallback do |error|
      # Queue for later delivery
      EmailRetryJob.perform_later(
        mailer: self.class.name,
        action: action_name,
        params: @params
      )
      
      # Return fake message to prevent errors
      Mail::Message.new
    end
  end

  around_action :wrap_in_circuit

  private

  def wrap_in_circuit
    circuit(:email_service).wrap { yield }
  end
end

# Retry job
class EmailRetryJob < ApplicationJob
  queue_as :low

  def perform(mailer:, action:, params:)
    mailer.constantize.send(action, **params).deliver_now
  end
end
```

## Health Checks

```ruby
# app/controllers/health_controller.rb
class HealthController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    render json: health_status, status: overall_status
  end

  private

  def health_status
    {
      status: overall_status == 200 ? 'healthy' : 'degraded',
      timestamp: Time.current.iso8601,
      services: circuit_statuses,
      database: database_status,
      redis: redis_status,
      version: Rails.application.config.version
    }
  end

  def circuit_statuses
    BreakerMachines.registry.all.map do |name, circuit|
      {
        name: name,
        state: circuit.state,
        healthy: circuit.closed?,
        failure_count: circuit.failure_count,
        last_failure: circuit.last_failure_time&.iso8601
      }
    end
  end

  def database_status
    ActiveRecord::Base.connection.active?
    'connected'
  rescue
    'disconnected'
  end

  def redis_status
    Redis.current.ping == 'PONG' ? 'connected' : 'disconnected'
  rescue
    'disconnected'
  end

  def overall_status
    critical_circuits = [:auth_service, :database_write, :payment]
    critical_open = BreakerMachines.registry.all.any? do |name, circuit|
      critical_circuits.include?(name) && circuit.open?
    end
    
    critical_open ? 503 : 200
  end
end
```

## Rails Console Helpers

```ruby
# lib/tasks/circuits.rake
namespace :circuits do
  desc "Show all circuit states"
  task status: :environment do
    puts "Circuit Breaker Status"
    puts "=" * 50
    
    BreakerMachines.registry.all.each do |name, circuit|
      puts "#{name}:"
      puts "  State: #{circuit.state}"
      puts "  Failures: #{circuit.failure_count}"
      puts "  Last Failure: #{circuit.last_failure_time}"
      puts ""
    end
  end
  
  desc "Reset all circuits"
  task reset: :environment do
    BreakerMachines.registry.all.each do |name, circuit|
      circuit.reset!
      puts "Reset circuit: #{name}"
    end
  end
  
  desc "Open a specific circuit"
  task :open, [:name] => :environment do |t, args|
    circuit = BreakerMachines.registry.get(args[:name])
    if circuit
      circuit.trip!
      puts "Opened circuit: #{args[:name]}"
    else
      puts "Circuit not found: #{args[:name]}"
    end
  end
end
```

## Testing in Rails

```ruby
# spec/support/circuit_breaker_helper.rb
module CircuitBreakerHelper
  def stub_circuit_open(circuit_name)
    circuit = BreakerMachines.registry.get(circuit_name)
    allow(circuit).to receive(:state).and_return(:open)
  end
  
  def stub_circuit_closed(circuit_name)
    circuit = BreakerMachines.registry.get(circuit_name)
    allow(circuit).to receive(:state).and_return(:closed)
  end
  
  def with_circuit_storage(storage_type)
    original = BreakerMachines.config.default_storage
    BreakerMachines.config.default_storage = storage_type
    yield
  ensure
    BreakerMachines.config.default_storage = original
  end
end

RSpec.configure do |config|
  config.include CircuitBreakerHelper
  
  config.before(:each) do
    # Always use memory storage in tests
    BreakerMachines.configure do |c|
      c.default_storage = :memory
      c.log_events = false
    end
    
    # Reset all circuits
    BreakerMachines.registry.clear
  end
end
```

## Best Practices

1. **Use cache storage in production** for distributed state
2. **Monitor circuit states** through health endpoints
3. **Set appropriate thresholds** based on service SLAs
4. **Use fallbacks** that degrade gracefully
5. **Test circuit behavior** in your integration tests
6. **Log circuit events** for debugging and alerting
7. **Configure per-environment** settings appropriately

## Next Steps

- Review [Testing Guide](TESTING.md) for Rails-specific testing
- Set up [Monitoring](OBSERVABILITY.md) for production
- Explore [Advanced Patterns](ADVANCED_PATTERNS.md) for complex scenarios