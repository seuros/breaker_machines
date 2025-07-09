# BreakerMachines Test Dummy App

This is a minimal Rails API application for testing BreakerMachines circuit breaker functionality.

## Running the App

From the gem root directory:

```bash
cd test/dummy
bundle exec rails server
```

## Endpoints

### Weather API (Protected by Circuit Breaker)

```bash
# Get weather data (20% chance of random failure)
curl http://localhost:3000/weather

# Response when circuit is closed:
{
  "temperature": 75,
  "condition": "sunny",
  "source": "live",
  "timestamp": "2024-01-15T10:30:00Z"
}

# Response when circuit is open (fallback):
{
  "temperature": 72,
  "condition": "unknown",
  "source": "fallback",
  "error": "Weather service unavailable",
  "circuit_open": true
}
```

### Force Failure (For Testing)

```bash
# Trigger a failure
curl http://localhost:3000/force_failure

# After 3 failures, the circuit opens
```

### Circuit Status

```bash
# View all circuits
curl http://localhost:3000/circuits

# Response:
{
  "circuits": [
    {
      "name": "weather_api",
      "state": "open",
      "failure_count": 3,
      "success_count": 10,
      "last_failure_at": "2024-01-15T10:30:00Z",
      "config": {
        "failure_threshold": 3,
        "failure_window": 60,
        "reset_timeout": 30
      }
    }
  ]
}

# Reset a circuit
curl -X POST http://localhost:3000/circuits/weather_api/reset
```

## Circuit Configuration

The weather API circuit is configured in `app/controllers/weather_controller.rb`:

- **Threshold**: Opens after 3 failures within 60 seconds
- **Reset**: Attempts to close after 30 seconds
- **Timeout**: 5 second timeout for API calls
- **Fallback**: Returns cached weather data when open

### Health Check

```bash
# Check application health and circuit status
curl http://localhost:3000/health
```

### Test Endpoints

```bash
# Process payment through circuit breaker
curl http://localhost:3000/test/payment?amount=50.00

# Send notification through circuit breaker
curl http://localhost:3000/test/notification

# Get all circuit statuses
curl http://localhost:3000/test/status

# Force payment circuit to open
curl -X POST http://localhost:3000/test/trip_payment

# Reset all test circuits
curl -X POST http://localhost:3000/test/reset
```

## Testing

From the gem root:

```bash
bundle exec rails test test/integration/circuit_breaker_test.rb
```

The test suite demonstrates:
- Normal operation when circuit is closed
- Fallback behavior when circuit is open
- Circuit opening after threshold failures
- Manual circuit reset
- Health check functionality

## How It Works

1. The `WeatherController` includes `BreakerMachines::DSL`
2. Defines a circuit breaker named `:weather_api` with configuration
3. Wraps the external API call in `circuit(:weather_api).wrap`
4. If the circuit is open, the fallback block is executed instead
5. The circuit tracks failures and opens when threshold is reached

This is a minimal example. In production, you might:
- Use Redis storage for distributed circuit state
- Add metrics and monitoring
- Configure different thresholds for different services
- Use circuit state to make smart routing decisions