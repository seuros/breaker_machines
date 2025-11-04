# breaker-machines

High-performance circuit breaker implementation with state machine-based lifecycle management.

This crate provides a complete, standalone circuit breaker that can be used independently or as a performance backend for the [breaker_machines](https://github.com/seuros/breaker_machines) Ruby gem.

## Features

- **State Machine**: Built on [state-machines](https://crates.io/crates/state-machines) with dynamic mode for runtime state transitions
- **Thread-safe Storage**: Sliding window event tracking with `RwLock` for concurrent access
- **Monotonic Time**: Uses `Instant` to prevent NTP clock skew issues
- **Builder API**: Ergonomic fluent configuration interface
- **Callbacks**: Type-safe hooks for state transitions (`on_open`, `on_close`, `on_half_open`)
- **Fallback Support**: Return default values when circuit is open
- **Rate-based Thresholds**: Trip circuit based on failure percentage, not just absolute counts
- **Exception Filtering**: Classify which errors should trip the circuit using custom predicates
- **Bulkheading**: Limit concurrent operations to prevent resource exhaustion
- **Jitter Support**: Configurable jitter using [chrono-machines](https://crates.io/crates/chrono-machines) to prevent thundering herd
- **Storage Abstraction**: Pluggable backends via `StorageBackend` trait
- **Zero-cost**: Optimized for high-performance applications

## Performance

Approximately 65x faster than Ruby-based storage for sliding window calculations (10,000 operations: 0.011s vs 0.735s).

## Usage

### Basic Example

```rust
use breaker_machines::CircuitBreaker;

let mut circuit = CircuitBreaker::builder("payment_api")
    .failure_threshold(5)
    .failure_window_secs(60.0)
    .half_open_timeout_secs(30.0)
    .success_threshold(2)
    .on_open(|name| eprintln!("Circuit {} opened!", name))
    .build();

// Execute with circuit protection
let result = circuit.call(|| {
    // Your service call here
    stripe_api.charge(amount)
});

match result {
    Ok(payment) => println!("Payment successful: {:?}", payment),
    Err(e) => eprintln!("Payment failed: {}", e),
}

// Check circuit state
if circuit.is_open() {
    println!("Circuit is open, falling back to queue");
}
```

### With Callbacks

```rust
use breaker_machines::CircuitBreaker;

let mut circuit = CircuitBreaker::builder("api")
    .failure_threshold(3)
    .on_open(|name| {
        // Send alert to PagerDuty
        alert_ops(name);
    })
    .on_close(|name| {
        // Log recovery
        info!("Circuit {} recovered", name);
    })
    .build();

circuit.call(|| api_request())?;
```

### With Jitter (Thundering Herd Prevention)

```rust
use breaker_machines::CircuitBreaker;

let mut circuit = CircuitBreaker::builder("distributed_api")
    .failure_threshold(5)
    .half_open_timeout_secs(30.0)
    .jitter_factor(0.1) // 10% jitter = 90-100% of timeout
    .on_open(|name| eprintln!("Circuit {} opened!", name))
    .build();

// With jitter, multiple circuits won't retry simultaneously
// Prevents thundering herd problem in distributed systems
circuit.call(|| api_request())?;
```

### With Fallback (v0.2.0+)

```rust
use breaker_machines::{CircuitBreaker, CallOptions};

let mut circuit = CircuitBreaker::builder("api")
    .failure_threshold(3)
    .build();

// Provide a fallback when circuit is open
let result = circuit.call((
    || expensive_api_call(),
    CallOptions::new().with_fallback(|ctx| {
        // Access circuit name, opened_at timestamp, and state
        eprintln!("Circuit '{}' is {}, using cache", ctx.circuit_name, ctx.state);
        Ok(get_cached_value())
    }),
));

// Fallback is only called when circuit is Open
// Normal calls work as before: circuit.call(|| api_request())
```

### Rate-based Thresholds (v0.2.0+)

```rust
use breaker_machines::CircuitBreaker;

// Trip circuit when 50% of calls fail (modern approach)
let mut circuit = CircuitBreaker::builder("api")
    .failure_rate(0.5)           // 50% failure rate threshold
    .minimum_calls(10)            // Need at least 10 calls before evaluating rate
    .disable_failure_threshold()  // Don't use absolute count
    .build();

// Or combine both: whichever threshold is hit first opens the circuit
let mut circuit = CircuitBreaker::builder("api")
    .failure_threshold(100)      // Absolute: 100 failures
    .failure_rate(0.3)            // OR 30% failure rate
    .minimum_calls(20)            // (after at least 20 calls)
    .build();
```

### Exception Filtering (v0.3.0+)

```rust
use breaker_machines::{CircuitBreaker, PredicateClassifier};
use std::sync::Arc;

#[derive(Debug)]
enum ApiError {
    ClientError(u16),  // 4xx - client's fault
    ServerError(u16),  // 5xx - our fault
}

// Only trip circuit on server errors (5xx), ignore client errors (4xx)
let classifier = Arc::new(PredicateClassifier::new(|ctx| {
    ctx.error
        .downcast_ref::<ApiError>()
        .map(|e| matches!(e, ApiError::ServerError(_)))
        .unwrap_or(true) // Trip on unknown errors
}));

let mut circuit = CircuitBreaker::builder("api")
    .failure_threshold(5)
    .failure_classifier(classifier)
    .build();

// Client errors don't trip the circuit
circuit.call(|| Err::<(), _>(ApiError::ClientError(400)))?;
assert!(circuit.is_closed());

// Server errors do trip the circuit
for _ in 0..5 {
    let _ = circuit.call(|| Err::<(), _>(ApiError::ServerError(500)));
}
assert!(circuit.is_open());
```

### Bulkheading (v0.3.0+)

```rust
use breaker_machines::{CircuitBreaker, CircuitError};

// Limit concurrent operations to prevent resource exhaustion
let mut circuit = CircuitBreaker::builder("database")
    .max_concurrency(10)  // Max 10 concurrent DB connections
    .failure_threshold(5)
    .build();

// Up to 10 calls can run concurrently
let result = circuit.call(|| {
    database.query("SELECT * FROM users")
});

match result {
    Ok(rows) => println!("Query successful: {} rows", rows.len()),
    Err(CircuitError::BulkheadFull { circuit, limit }) => {
        // Too many concurrent calls, circuit is protecting resources
        eprintln!("Circuit '{}' at capacity (limit: {})", circuit, limit);
    }
    Err(CircuitError::Open { .. }) => {
        eprintln!("Circuit is open, database may be down");
    }
    Err(e) => eprintln!("Query failed: {}", e),
}
```

Bulkheading is especially useful for:
- **Database connection pools**: Prevent connection exhaustion
- **API rate limiting**: Stay within provider limits
- **Thread pool protection**: Avoid starvation in executors
- **Memory-intensive operations**: Limit parallel processing

### Custom Storage Backend

```rust
use breaker_machines::{CircuitBreaker, MemoryStorage};
use std::sync::Arc;

// Default in-memory storage with event tracking
let storage = Arc::new(MemoryStorage::new());

let mut circuit = CircuitBreaker::builder("api")
    .storage(storage)
    .build();
```

### NullStorage for Testing/Benchmarking

```rust
use breaker_machines::{CircuitBreaker, NullStorage};
use std::sync::Arc;

// No-op storage: discards all events, returns zero counts
// Useful for testing state machine logic without storage overhead
let storage = Arc::new(NullStorage::new());

let mut circuit = CircuitBreaker::builder("benchmark_test")
    .storage(storage)
    .build();

// Circuit will never open (no failure tracking)
circuit.call(|| Err::<(), _>("always fails"))?;
assert!(circuit.is_closed()); // Still closed
```

## State Machine

The circuit breaker implements a state machine with three states:

```
Closed → Open → HalfOpen → Closed
   ↑                 ↓
   └─────────────────┘
```

- **Closed**: Normal operation, tracking failures
- **Open**: Circuit tripped, rejecting calls immediately
- **HalfOpen**: Testing recovery with limited requests

Transitions are guarded by configurable thresholds and timeouts.

## Architecture

- **Dynamic Mode**: Uses runtime state dispatch via `state-machines` crate
- **Guards**: Validate transitions based on failure counts and timeouts
- **State Data**: Tracks `opened_at` timestamps and success counters
- **Context**: Shared circuit name, config, and storage across states

## Ruby FFI Integration

This crate can be used as a high-performance backend for Ruby applications via Magnus FFI bindings. See the parent [breaker_machines](https://github.com/seuros/breaker_machines) gem for Ruby usage.

## Examples

See `examples/` directory for more usage patterns:

- `basic.rs` - Simple circuit with builder API and callbacks

Run examples with:
```bash
cargo run --example basic
```

## Testing

```bash
cargo test
```

All tests use the dynamic state machine with proper guard validation.

## License

MIT
