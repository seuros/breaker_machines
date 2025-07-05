# Async Storage Examples for BreakerMachines

When using BreakerMachines in `fiber_safe` mode with Fiber-based servers like Falcon, you'll want storage backends that don't block the event loop. Here are examples of how to implement async-compatible storage.

## Async Redis Storage

This example uses the `async-redis` gem for non-blocking Redis operations:

```ruby
# Gemfile
gem 'async-redis'

# lib/async_redis_circuit_storage.rb
require 'async/redis'

class AsyncRedisCircuitStorage < BreakerMachines::Storage::Base
  def initialize(redis_url: ENV['REDIS_URL'], prefix: 'circuit_breaker:')
    @client = Async::Redis::Client.new(Async::Redis.parse_url(redis_url))
    @prefix = prefix
  end

  def get_status(circuit_name)
    key = "#{@prefix}#{circuit_name}"

    # All Redis operations are non-blocking in async context
    data = @client.hgetall(key).wait
    return nil if data.empty?

    {
      status: data['status']&.to_sym,
      opened_at: data['opened_at']&.to_f,
      failure_count: data['failure_count']&.to_i || 0,
      success_count: data['success_count']&.to_i || 0,
      last_failure_at: data['last_failure_at']&.to_f
    }
  end

  def set_status(circuit_name, status, opened_at = nil)
    key = "#{@prefix}#{circuit_name}"

    @client.multi do |transaction|
      transaction.hset(key, 'status', status.to_s)
      transaction.hset(key, 'opened_at', opened_at) if opened_at
      transaction.expire(key, 3600) # Auto-cleanup after 1 hour
    end.wait
  end

  def record_failure(circuit_name, duration = nil)
    key = "#{@prefix}#{circuit_name}"

    @client.multi do |transaction|
      transaction.hincrby(key, 'failure_count', 1)
      transaction.hset(key, 'last_failure_at', Time.now.to_f)
      transaction.hset(key, 'last_failure_duration', duration) if duration
    end.wait
  end

  def record_success(circuit_name, duration = nil)
    key = "#{@prefix}#{circuit_name}"

    @client.multi do |transaction|
      transaction.hincrby(key, 'success_count', 1)
      transaction.hset(key, 'last_success_duration', duration) if duration
    end.wait
  end

  def failure_count(circuit_name, window = nil)
    if window
      # For windowed counts, use Redis sorted sets
      score_key = "#{@prefix}#{circuit_name}:failures"
      min_score = Time.now.to_f - window
      @client.zcount(score_key, min_score, '+inf').wait
    else
      get_status(circuit_name)[:failure_count] || 0
    end
  end

  def success_count(circuit_name, window = nil)
    if window
      score_key = "#{@prefix}#{circuit_name}:successes"
      min_score = Time.now.to_f - window
      @client.zcount(score_key, min_score, '+inf').wait
    else
      get_status(circuit_name)[:success_count] || 0
    end
  end

  def reset(circuit_name)
    @client.del("#{@prefix}#{circuit_name}").wait
  end

  def close
    @client.close
  end
end
```

## Usage with Falcon Server

```ruby
# config.ru
require 'falcon'
require 'async'
require 'breaker_machines'
require_relative 'lib/async_redis_circuit_storage'

# Configure BreakerMachines for fiber-safe mode
BreakerMachines.configure do |config|
  config.fiber_safe = true
  config.default_storage = AsyncRedisCircuitStorage.new
end

class MyAPI
  include BreakerMachines::DSL

  circuit :external_api, fiber_safe: true do
    threshold failures: 5, within: 60
    reset_after 30
    timeout 3  # Safe cooperative timeout in fiber mode!

    fallback do |error|
      { error: "Service temporarily unavailable", cached: true }
    end

    on_open do
      # This can also be async
      Async do
        # Send alert to monitoring service
        AsyncHTTP::Internet.new.post(
          'https://monitoring.example.com/alerts',
          { circuit: 'external_api', status: 'open' }
        )
      end
    end
  end

  def fetch_data
    circuit(:external_api).wrap do
      # This returns an Async::Task when called within Falcon
      Async::HTTP::Internet.new.get('https://api.example.com/data')
    end
  end
end

# Falcon app
run lambda { |env|
  Async do
    api = MyAPI.new
    result = api.fetch_data

    [200, {'Content-Type' => 'application/json'}, [result.to_json]]
  end.wait
}
```

## Async PostgreSQL Storage

Using the `async-postgres` gem:

```ruby
# Gemfile
gem 'async-postgres'

# lib/async_postgres_circuit_storage.rb
require 'async/postgres'

class AsyncPostgresCircuitStorage < BreakerMachines::Storage::Base
  def initialize(connection_string: ENV['DATABASE_URL'])
    @connection = Async::Postgres.connect(connection_string)
    ensure_table_exists
  end

  def get_status(circuit_name)
    result = @connection.exec_params(
      'SELECT * FROM circuit_breaker_states WHERE circuit_name = $1',
      [circuit_name]
    ).wait

    return nil if result.ntuples == 0

    row = result.first
    {
      status: row['status'].to_sym,
      opened_at: row['opened_at']&.to_f,
      failure_count: row['failure_count'].to_i,
      success_count: row['success_count'].to_i,
      last_failure_at: row['last_failure_at']&.to_f
    }
  end

  def set_status(circuit_name, status, opened_at = nil)
    @connection.exec_params(
      <<~SQL,
        INSERT INTO circuit_breaker_states
          (circuit_name, status, opened_at, updated_at)
        VALUES ($1, $2, $3, NOW())
        ON CONFLICT (circuit_name)
        DO UPDATE SET
          status = EXCLUDED.status,
          opened_at = EXCLUDED.opened_at,
          updated_at = EXCLUDED.updated_at
      SQL
      [circuit_name, status.to_s, opened_at ? Time.at(opened_at) : nil]
    ).wait
  end

  def record_failure(circuit_name, duration = nil)
    @connection.exec_params(
      <<~SQL,
        INSERT INTO circuit_breaker_states
          (circuit_name, failure_count, last_failure_at, updated_at)
        VALUES ($1, 1, NOW(), NOW())
        ON CONFLICT (circuit_name)
        DO UPDATE SET
          failure_count = circuit_breaker_states.failure_count + 1,
          last_failure_at = NOW(),
          updated_at = NOW()
      SQL
      [circuit_name]
    ).wait
  end

  def record_success(circuit_name, duration = nil)
    @connection.exec_params(
      <<~SQL,
        INSERT INTO circuit_breaker_states
          (circuit_name, success_count, updated_at)
        VALUES ($1, 1, NOW())
        ON CONFLICT (circuit_name)
        DO UPDATE SET
          success_count = circuit_breaker_states.success_count + 1,
          updated_at = NOW()
      SQL
      [circuit_name]
    ).wait
  end

  private

  def ensure_table_exists
    @connection.exec(<<~SQL).wait
      CREATE TABLE IF NOT EXISTS circuit_breaker_states (
        circuit_name VARCHAR(255) PRIMARY KEY,
        status VARCHAR(50) NOT NULL DEFAULT 'closed',
        opened_at TIMESTAMP,
        failure_count INTEGER DEFAULT 0,
        success_count INTEGER DEFAULT 0,
        last_failure_at TIMESTAMP,
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
      );

      CREATE INDEX IF NOT EXISTS idx_circuit_breaker_updated_at
        ON circuit_breaker_states(updated_at);
    SQL
  end
end
```

## Testing Async Storage

```ruby
require 'async/rspec'

RSpec.describe AsyncRedisCircuitStorage do
  include Async::RSpec

  let(:storage) { described_class.new }

  it "records failures without blocking" do
    # This test runs in an async context
    storage.record_failure('test_circuit', 0.5)

    status = storage.get_status('test_circuit')
    expect(status[:failure_count]).to eq(1)
  end

  it "handles concurrent operations" do
    # Run 100 concurrent operations
    tasks = 100.times.map do
      Async do
        storage.record_failure('concurrent_test')
      end
    end

    # Wait for all to complete
    tasks.each(&:wait)

    status = storage.get_status('concurrent_test')
    expect(status[:failure_count]).to eq(100)
  end
end
```

## Best Practices

1. **Always use `.wait` on async operations** when you need the result immediately
2. **Batch operations** where possible to reduce round trips
3. **Use connection pooling** for better performance under load
4. **Set reasonable timeouts** on storage operations
5. **Consider using TTL** for automatic cleanup of old circuit states

## Performance Considerations

In fiber_safe mode with async storage:
- Multiple circuits can check their state concurrently without blocking
- Storage operations yield to the scheduler during I/O
- The event loop remains responsive even under heavy circuit breaker usage
- You can safely use timeouts without the dangers of Thread#kill

This makes BreakerMachines ideal for high-concurrency Fiber-based applications!
