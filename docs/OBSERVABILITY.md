# Observability and Monitoring

## Overview

BreakerMachines provides comprehensive observability features through ActiveSupport::Notifications, custom callbacks, and integration points for your monitoring stack.

## Built-in Events

BreakerMachines leverages `ActiveSupport::Notifications` to emit events for all significant circuit breaker activities. These events can be used to integrate with your monitoring and alerting systems. For details on enabling event logging, refer to the [Configuration Guide](CONFIGURATION.md).

### Circuit State Events

```ruby
# Subscribe to all circuit events
ActiveSupport::Notifications.subscribe(/^breaker_machines\./) do |name, start, finish, id, payload|
  event_type = name.split('.').last
  circuit_name = payload[:circuit]
  
  case event_type
  when 'opened'
    # Circuit opened (started rejecting requests)
    StatsD.increment("circuit.opened", tags: ["circuit:#{circuit_name}"])
    AlertManager.trigger(:circuit_open, circuit: circuit_name)
    
  when 'closed'
    # Circuit closed (recovered)
    StatsD.increment("circuit.closed", tags: ["circuit:#{circuit_name}"])
    AlertManager.resolve(:circuit_open, circuit: circuit_name)
    
  when 'half_opened'
    # Circuit testing recovery
    StatsD.increment("circuit.half_opened", tags: ["circuit:#{circuit_name}"])
    
  when 'rejected'
    # Request rejected by open circuit
    StatsD.increment("circuit.rejected", tags: ["circuit:#{circuit_name}"])
    
  when 'success'
    # Successful call through circuit
    duration = (finish - start) * 1000  # Convert to milliseconds
    StatsD.timing("circuit.success", duration, tags: ["circuit:#{circuit_name}"])
    
  when 'failure'
    # Failed call (counts toward opening)
    StatsD.increment("circuit.failure", tags: ["circuit:#{circuit_name}"])
    error_class = payload[:error]&.class&.name
    StatsD.increment("circuit.error", tags: ["circuit:#{circuit_name}", "error:#{error_class}"])
  end
end
```

### Bulkhead Events

```ruby
ActiveSupport::Notifications.subscribe("breaker_machines.bulkhead_rejected") do |_, _, _, _, payload|
  circuit_name = payload[:circuit]
  current_count = payload[:current_count]
  max_concurrent = payload[:max_concurrent]
  
  StatsD.gauge("circuit.concurrent", current_count, tags: ["circuit:#{circuit_name}"])
  StatsD.increment("circuit.bulkhead_rejected", tags: ["circuit:#{circuit_name}"])
  
  # Alert if consistently at capacity
  if current_count >= max_concurrent
    AlertManager.warning(:at_capacity, 
      circuit: circuit_name,
      message: "Circuit at capacity: #{current_count}/#{max_concurrent}"
    )
  end
end
```

## Custom Instrumentation

### Adding Custom Metrics

```ruby
class InstrumentedService
  include BreakerMachines::DSL

  circuit :api do
    threshold failures: 3, within: 1.minute
    
    # Wrap the execution with custom instrumentation
    around_execution do |block|
      start_time = Time.now
      result = nil
      
      begin
        # Track concurrent executions
        StatsD.increment("api.calls.started")
        Metrics.gauge("api.concurrent_calls", current_concurrent_calls)
        
        result = block.call
        
        # Track success metrics
        duration = Time.now - start_time
        StatsD.timing("api.call_duration", duration * 1000)
        StatsD.increment("api.calls.success")
        
        result
      rescue => e
        # Track failure metrics
        duration = Time.now - start_time
        StatsD.timing("api.call_duration", duration * 1000)
        StatsD.increment("api.calls.failure", tags: ["error:#{e.class}"])
        
        raise
      ensure
        StatsD.increment("api.calls.completed")
      end
    end
  end
  
  private
  
  def current_concurrent_calls
    # Your implementation to track concurrent calls
  end
end
```

### Request Context

```ruby
class ContextualCircuit
  include BreakerMachines::DSL

  circuit :contextual do
    on_success do |result|
      # Add context to metrics
      request_id = Thread.current[:request_id]
      user_id = Thread.current[:user_id]
      
      StatsD.increment("circuit.success",
        tags: [
          "circuit:contextual",
          "user:#{user_id}",
          "request:#{request_id}"
        ]
      )
    end
    
    on_failure do |error|
      # Log with full context
      Rails.logger.error({
        event: "circuit_failure",
        circuit: "contextual",
        error: error.class.name,
        message: error.message,
        backtrace: error.backtrace[0..5],
        request_id: Thread.current[:request_id],
        user_id: Thread.current[:user_id]
      }.to_json)
    end
  end
end
```

## Monitoring Dashboards

### Prometheus Integration

```ruby
# config/initializers/prometheus.rb
require 'prometheus/client'

prometheus = Prometheus::Client.registry

# Circuit state gauge
CIRCUIT_STATE = Prometheus::Client::Gauge.new(
  :circuit_breaker_state,
  docstring: 'Current state of circuit breakers',
  labels: [:circuit_name]
)
prometheus.register(CIRCUIT_STATE)

# Request counter
CIRCUIT_REQUESTS = Prometheus::Client::Counter.new(
  :circuit_breaker_requests_total,
  docstring: 'Total requests through circuit breakers',
  labels: [:circuit_name, :result]
)
prometheus.register(CIRCUIT_REQUESTS)

# Request duration histogram
CIRCUIT_DURATION = Prometheus::Client::Histogram.new(
  :circuit_breaker_request_duration_seconds,
  docstring: 'Request duration through circuit breakers',
  labels: [:circuit_name]
)
prometheus.register(CIRCUIT_DURATION)

# Subscribe to events
ActiveSupport::Notifications.subscribe(/^breaker_machines\./) do |name, start, finish, id, payload|
  circuit_name = payload[:circuit]
  
  case name
  when 'breaker_machines.success'
    CIRCUIT_REQUESTS.increment(labels: { circuit_name: circuit_name, result: 'success' })
    CIRCUIT_DURATION.observe(finish - start, labels: { circuit_name: circuit_name })
    
  when 'breaker_machines.failure'
    CIRCUIT_REQUESTS.increment(labels: { circuit_name: circuit_name, result: 'failure' })
    
  when 'breaker_machines.rejected'
    CIRCUIT_REQUESTS.increment(labels: { circuit_name: circuit_name, result: 'rejected' })
    
  when 'breaker_machines.opened'
    CIRCUIT_STATE.set(2, labels: { circuit_name: circuit_name })  # 2 = open
    
  when 'breaker_machines.closed'
    CIRCUIT_STATE.set(0, labels: { circuit_name: circuit_name })  # 0 = closed
    
  when 'breaker_machines.half_opened'
    CIRCUIT_STATE.set(1, labels: { circuit_name: circuit_name })  # 1 = half_open
  end
end
```

### Grafana Dashboard Example

```json
{
  "dashboard": {
    "title": "Circuit Breakers",
    "panels": [
      {
        "title": "Circuit States",
        "targets": [{
          "expr": "circuit_breaker_state",
          "legendFormat": "{{circuit_name}}"
        }]
      },
      {
        "title": "Request Rate",
        "targets": [{
          "expr": "rate(circuit_breaker_requests_total[5m])",
          "legendFormat": "{{circuit_name}} - {{result}}"
        }]
      },
      {
        "title": "Success Rate",
        "targets": [{
          "expr": "rate(circuit_breaker_requests_total{result=\"success\"}[5m]) / rate(circuit_breaker_requests_total[5m])",
          "legendFormat": "{{circuit_name}}"
        }]
      },
      {
        "title": "P95 Latency",
        "targets": [{
          "expr": "histogram_quantile(0.95, rate(circuit_breaker_request_duration_seconds_bucket[5m]))",
          "legendFormat": "{{circuit_name}}"
        }]
      }
    ]
  }
}
```

## Health Checks

### Circuit Health Endpoint

```ruby
# app/controllers/health_controller.rb
class HealthController < ApplicationController
  def circuits
    circuits = BreakerMachines.registry.all.map do |name, circuit|
      {
        name: name,
        state: circuit.state,
        healthy: circuit.closed?,
        failure_count: circuit.failure_count,
        last_failure: circuit.last_failure_time,
        config: {
          threshold: circuit.config[:failure_threshold],
          window: circuit.config[:window],
          reset_timeout: circuit.config[:reset_timeout]
        }
      }
    end
    
    overall_healthy = circuits.all? { |c| c[:healthy] }
    
    render json: {
      healthy: overall_healthy,
      circuits: circuits,
      timestamp: Time.now.iso8601
    }, status: overall_healthy ? :ok : :service_unavailable
  end
end
```

### Kubernetes Probes

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  containers:
  - name: app
    livenessProbe:
      httpGet:
        path: /health/circuits
        port: 3000
      initialDelaySeconds: 30
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      httpGet:
        path: /health/circuits
        port: 3000
      periodSeconds: 5
      successThreshold: 1
      failureThreshold: 2
```

## Alerting

### PagerDuty Integration

```ruby
class PagerDutyNotifier
  def self.setup
    ActiveSupport::Notifications.subscribe("breaker_machines.opened") do |_, _, _, _, payload|
      circuit_name = payload[:circuit]
      
      # Only alert for critical circuits
      if critical_circuit?(circuit_name)
        PagerDuty.trigger(
          service_key: ENV['PAGERDUTY_SERVICE_KEY'],
          incident_key: "circuit_#{circuit_name}_open",
          description: "Circuit breaker '#{circuit_name}' has opened",
          details: {
            circuit: circuit_name,
            timestamp: Time.now.iso8601,
            environment: Rails.env
          }
        )
      end
    end
    
    ActiveSupport::Notifications.subscribe("breaker_machines.closed") do |_, _, _, _, payload|
      circuit_name = payload[:circuit]
      
      if critical_circuit?(circuit_name)
        PagerDuty.resolve(
          service_key: ENV['PAGERDUTY_SERVICE_KEY'],
          incident_key: "circuit_#{circuit_name}_open"
        )
      end
    end
  end
  
  def self.critical_circuit?(name)
    %i[payment auth primary_database].include?(name.to_sym)
  end
end
```

### Slack Notifications

```ruby
class SlackNotifier
  def self.setup
    ActiveSupport::Notifications.subscribe("breaker_machines.opened") do |_, _, _, _, payload|
      circuit_name = payload[:circuit]
      
      notify(
        channel: "#alerts",
        color: "danger",
        title: "Circuit Breaker Opened",
        text: "Circuit '#{circuit_name}' is now rejecting requests",
        fields: [
          { title: "Circuit", value: circuit_name, short: true },
          { title: "Time", value: Time.now.strftime("%H:%M:%S"), short: true }
        ]
      )
    end
  end
  
  def self.notify(message)
    # Your Slack notification implementation
  end
end
```

## Performance Monitoring

For performance monitoring in asynchronous environments, especially with `fiber_safe` mode, refer to the [Async Mode](ASYNC.md) documentation.

### APM Integration

```ruby
# NewRelic example
class NewRelicInstrumented
  include BreakerMachines::DSL

  circuit :external_api do
    around_execution do |block|
      NewRelic::Agent.record_metric(
        "Custom/CircuitBreaker/#{circuit_name}/calls",
        1
      )
      
      segment = NewRelic::Agent::Tracer.start_segment(
        name: "CircuitBreaker/#{circuit_name}"
      )
      
      begin
        result = block.call
        NewRelic::Agent.record_metric(
          "Custom/CircuitBreaker/#{circuit_name}/success",
          1
        )
        result
      rescue => e
        NewRelic::Agent.record_metric(
          "Custom/CircuitBreaker/#{circuit_name}/failure",
          1
        )
        NewRelic::Agent.notice_error(e)
        raise
      ensure
        segment&.finish
      end
    end
  end
  
  private
  
  def circuit_name
    'external_api'
  end
end
```

## Debugging

For more advanced debugging techniques and how to integrate with your monitoring systems, consult the [Configuration Guide](CONFIGURATION.md) for logging options and the [Testing Guide](TESTING.md) for simulating scenarios.

### Circuit Inspector

```ruby
# lib/circuit_inspector.rb
class CircuitInspector
  def self.inspect_all
    BreakerMachines.registry.all.each do |name, circuit|
      puts "=" * 50
      puts "Circuit: #{name}"
      puts "State: #{circuit.state}"
      puts "Failures: #{circuit.failure_count}"
      puts "Last Failure: #{circuit.last_failure_time}"
      puts "Config: #{circuit.config.inspect}"
      puts "=" * 50
    end
  end
  
  def self.trace(circuit_name)
    original_logger = BreakerMachines.logger
    
    # Create detailed logger
    BreakerMachines.logger = Logger.new($stdout).tap do |logger|
      logger.level = Logger::DEBUG
    end
    
    # Subscribe to all events for this circuit
    ActiveSupport::Notifications.subscribe(/^breaker_machines\./) do |name, _, _, _, payload|
      next unless payload[:circuit] == circuit_name
      
      puts "[#{Time.now.iso8601}] #{name}: #{payload.inspect}"
    end
    
    yield
  ensure
    BreakerMachines.logger = original_logger
  end
end

# Usage
CircuitInspector.trace(:payment) do
  # Your code here - all circuit events will be logged
end
```

## Best Practices

1. **Monitor Key Metrics**: Track state changes, request rates, success rates, and latencies
2. **Set Up Alerts**: Alert on circuit opens for critical services
3. **Create Dashboards**: Visualize circuit health across your system
4. **Log Context**: Include request IDs and user context in circuit events
5. **Regular Reviews**: Analyze circuit behavior to tune thresholds

## Next Steps

- Learn about [Async Mode](ASYNC.md) for fiber-based monitoring
- Explore [Rails Integration](RAILS_INTEGRATION.md) for Rails-specific monitoring
- Review [Testing Patterns](TESTING.md) for monitoring in tests