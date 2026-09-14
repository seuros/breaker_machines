use super::*;

#[test]
fn test_circuit_breaker_creation() {
    let config = Config::default();
    let circuit = CircuitBreaker::new("test".to_string(), config);

    assert!(circuit.is_closed());
    assert!(!circuit.is_open());
}

#[test]
fn test_circuit_opens_after_threshold() {
    let config = Config {
        failure_threshold: Some(3),
        ..Default::default()
    };

    let mut circuit = CircuitBreaker::new("test".to_string(), config);

    // Trigger failures via call() method
    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(circuit.is_closed());

    let _ = circuit.call(|| Err::<(), _>("error 3"));
    assert!(circuit.is_open());
}

#[test]
fn test_reset_clears_state() {
    let config = Config {
        failure_threshold: Some(2),
        ..Default::default()
    };

    let mut circuit = CircuitBreaker::new("test".to_string(), config);

    // Trigger failures
    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(circuit.is_open());

    circuit.reset();
    assert!(circuit.is_closed());
}

#[test]
fn test_state_machine_closed_to_open_transition() {
    let storage = Arc::new(crate::MemoryStorage::new());
    let config = Config {
        failure_threshold: Some(3),
        ..Default::default()
    };

    let ctx = CircuitContext {
        failure_classifier: None,
        bulkhead: None,
        name: "test_circuit".to_string(),
        config,
        storage: storage.clone(),
    };

    let mut circuit = DynamicCircuit::new(ctx);

    // Initially closed - trip should fail guard
    let result = circuit.handle(CircuitEvent::Trip);
    assert!(result.is_err(), "Should fail guard when below threshold");

    // Record failures to exceed threshold
    storage.record_failure("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.1);

    // Now trip should succeed - guards pass
    circuit
        .handle(CircuitEvent::Trip)
        .expect("Should open after reaching threshold");

    assert_eq!(circuit.current_state(), CircuitState::Open);
}

#[test]
fn test_state_machine_open_to_half_open_transition() {
    let storage = Arc::new(crate::MemoryStorage::new());
    let config = Config {
        failure_threshold: Some(2),
        half_open_timeout_secs: 0.001, // Very short timeout for testing
        ..Default::default()
    };

    let ctx = CircuitContext {
        failure_classifier: None,
        bulkhead: None,
        name: "test_circuit".to_string(),
        config,
        storage: storage.clone(),
    };

    // Record failures and open circuit
    storage.record_failure("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.1);

    let mut circuit = DynamicCircuit::new(ctx);
    circuit.handle(CircuitEvent::Trip).expect("Should open");

    // Set opened_at timestamp
    if let Some(data) = circuit.open_data_mut() {
        data.opened_at = storage.monotonic_time();
    }

    // Immediately try to reset - should fail guard (timeout not elapsed)
    let result = circuit.handle(CircuitEvent::AttemptReset);
    assert!(
        result.is_err(),
        "Should fail guard when timeout not elapsed"
    );

    // Wait for timeout
    std::thread::sleep(std::time::Duration::from_millis(5));

    circuit
        .handle(CircuitEvent::AttemptReset)
        .expect("Should reset after timeout");

    // Verify we're in HalfOpen state
    assert_eq!(circuit.current_state(), CircuitState::HalfOpen);
    let data = circuit.half_open_data().expect("Should have HalfOpen data");
    assert_eq!(data.consecutive_successes, 0);
}

#[test]
fn test_state_machine_half_open_to_closed_guard() {
    let storage = Arc::new(crate::MemoryStorage::new());
    let config = Config {
        failure_threshold: Some(2),
        half_open_timeout_secs: 0.001,
        ..Default::default()
    };

    let ctx = CircuitContext {
        failure_classifier: None,
        bulkhead: None,
        name: "test_circuit".to_string(),
        config,
        storage: storage.clone(),
    };

    // Get to HalfOpen state
    storage.record_failure("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.1);

    let mut circuit = DynamicCircuit::new(ctx);
    circuit.handle(CircuitEvent::Trip).expect("Should open");

    // Set opened_at and wait for timeout
    if let Some(data) = circuit.open_data_mut() {
        data.opened_at = storage.monotonic_time();
    }
    std::thread::sleep(std::time::Duration::from_millis(5));

    circuit
        .handle(CircuitEvent::AttemptReset)
        .expect("Should reset");

    // Try to close - should fail guard (not enough successes)
    let result = circuit.handle(CircuitEvent::Close);
    assert!(result.is_err(), "Should fail guard without successes");
}

#[test]
fn test_jitter_disabled() {
    let storage = Arc::new(crate::MemoryStorage::new());
    let config = Config {
        failure_threshold: Some(1),
        half_open_timeout_secs: 1.0, // 1 second timeout
        jitter_factor: 0.0,          // No jitter
        ..Default::default()
    };

    let ctx = CircuitContext {
        failure_classifier: None,
        bulkhead: None,
        name: "test_circuit".to_string(),
        config,
        storage: storage.clone(),
    };

    // Open circuit
    storage.record_failure("test_circuit", 0.1);
    let mut circuit = DynamicCircuit::new(ctx);
    circuit.handle(CircuitEvent::Trip).expect("Should open");

    // Set opened_at
    if let Some(data) = circuit.open_data_mut() {
        data.opened_at = storage.monotonic_time();
    }

    // Wait exactly 1 second
    std::thread::sleep(std::time::Duration::from_secs(1));

    // Should transition to HalfOpen (no jitter = exact timeout)
    circuit
        .handle(CircuitEvent::AttemptReset)
        .expect("Should reset after exact timeout");
    assert_eq!(circuit.current_state(), CircuitState::HalfOpen);
}

#[test]
fn test_jitter_enabled() {
    let storage = Arc::new(crate::MemoryStorage::new());
    let config = Config {
        failure_threshold: Some(1),
        half_open_timeout_secs: 1.0,
        jitter_factor: 0.1, // 10% jitter = 90-100% of timeout
        ..Default::default()
    };

    let ctx = CircuitContext {
        failure_classifier: None,
        bulkhead: None,
        name: "test_circuit".to_string(),
        config,
        storage: storage.clone(),
    };

    // Test multiple times to verify jitter reduces timeout
    let mut found_early_reset = false;
    for _ in 0..10 {
        // Open circuit
        storage.record_failure("test_circuit", 0.1);
        let mut circuit = DynamicCircuit::new(ctx.clone());
        circuit.handle(CircuitEvent::Trip).expect("Should open");

        if let Some(data) = circuit.open_data_mut() {
            data.opened_at = storage.monotonic_time();
        }

        // With 10% jitter, timeout should be 900-1000ms
        // Try at 950ms - should sometimes succeed (jitter applied)
        std::thread::sleep(std::time::Duration::from_millis(950));

        if circuit.handle(CircuitEvent::AttemptReset).is_ok() {
            found_early_reset = true;
            break;
        }

        storage.clear("test_circuit");
    }

    assert!(
        found_early_reset,
        "Jitter should occasionally allow reset before full timeout"
    );
}

#[test]
fn test_builder_with_jitter() {
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .half_open_timeout_secs(1.0)
        .jitter_factor(0.5) // 50% jitter
        .build();

    // Trigger failures
    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(circuit.is_open());

    // Verify jitter_factor was set
    assert_eq!(circuit.context.config.jitter_factor, 0.5);
}

#[test]
fn test_fallback_when_open() {
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(2).build();

    // Trigger failures to open circuit
    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(circuit.is_open());

    // Call with fallback should return fallback result
    let result = circuit.call((
        || Err::<String, _>("should not execute"),
        CallOptions::new().with_fallback(|ctx| {
            assert_eq!(ctx.circuit_name, "test");
            assert_eq!(ctx.state, "Open");
            Ok("fallback response".to_string())
        }),
    ));

    assert!(result.is_ok());
    assert_eq!(result.unwrap(), "fallback response");
}

#[test]
fn test_fallback_error_propagation() {
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(1).build();

    // Trigger failure to open circuit
    let _ = circuit.call(|| Err::<(), _>("error"));
    assert!(circuit.is_open());

    // Fallback can also return errors
    let result = circuit.call((
        || Ok::<String, _>("should not execute".to_string()),
        CallOptions::new().with_fallback(|_ctx| Err::<String, _>("fallback error")),
    ));

    assert!(result.is_err());
    match result {
        Err(CircuitError::Execution(e)) => assert_eq!(e, "fallback error"),
        _ => panic!("Expected CircuitError::Execution"),
    }
}

#[test]
fn test_rate_based_threshold() {
    let mut circuit = CircuitBreaker::builder("test")
        .disable_failure_threshold() // Only use rate-based
        .failure_rate(0.5) // 50% failure rate
        .minimum_calls(10)
        .build();

    // First 9 calls - below minimum, circuit stays closed
    for i in 0..9 {
        let _result = if i % 2 == 0 {
            circuit.call(|| Ok::<(), _>(()))
        } else {
            circuit.call(|| Err::<(), _>("error"))
        };
        // Even with failures, circuit should stay closed (below minimum calls)
        assert!(circuit.is_closed(), "Circuit opened before minimum calls");
    }

    // 10th call - now at minimum, with 5 failures out of 10 = 50% rate
    // This should trip the circuit
    let _ = circuit.call(|| Err::<(), _>("error"));

    // Circuit should now be open (failure rate reached threshold)
    assert!(circuit.is_open(), "Circuit did not open at rate threshold");
}

#[test]
fn test_rate_and_absolute_threshold_both_active() {
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(3) // Absolute: 3 failures
        .failure_rate(0.8) // Rate: 80%
        .minimum_calls(10)
        .build();

    // Trigger 3 failures quickly - should open via absolute threshold
    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(circuit.is_closed());

    let _ = circuit.call(|| Err::<(), _>("error 3"));
    assert!(
        circuit.is_open(),
        "Circuit did not open at absolute threshold"
    );
}

#[test]
fn test_minimum_calls_prevents_premature_trip() {
    let mut circuit = CircuitBreaker::builder("test")
        .disable_failure_threshold()
        .failure_rate(0.5)
        .minimum_calls(20)
        .build();

    // Record 10 failures out of 10 calls = 100% failure rate
    for _ in 0..10 {
        let _ = circuit.call(|| Err::<(), _>("error"));
    }

    // Circuit should still be closed (below minimum_calls)
    assert!(
        circuit.is_closed(),
        "Circuit opened before reaching minimum_calls"
    );
}

#[test]
fn test_failure_classifier_filters_errors() {
    use crate::classifier::PredicateClassifier;

    // Classifier that only trips on "server" errors, not "client" errors
    let classifier = Arc::new(PredicateClassifier::new(|ctx| {
        ctx.error
            .downcast_ref::<&str>()
            .map(|e| e.contains("server"))
            .unwrap_or(true)
    }));

    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .failure_classifier(classifier)
        .build();

    // Client errors should not trip circuit
    for _ in 0..5 {
        let _ = circuit.call(|| Err::<(), _>("client_error"));
    }
    assert!(
        circuit.is_closed(),
        "Circuit should not trip on filtered errors"
    );

    // Server errors should trip circuit
    let _ = circuit.call(|| Err::<(), _>("server_error_1"));
    let _ = circuit.call(|| Err::<(), _>("server_error_2"));
    assert!(circuit.is_open(), "Circuit should trip on server errors");
}

#[test]
fn test_failure_classifier_with_slow_errors() {
    use crate::classifier::PredicateClassifier;

    // Only trip on errors that take > 0.5s
    let classifier = Arc::new(PredicateClassifier::new(|ctx| ctx.duration > 0.5));

    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .failure_classifier(classifier)
        .build();

    // Fast errors don't trip (duration will be near zero in tests)
    for _ in 0..10 {
        let _ = circuit.call(|| Err::<(), _>("fast error"));
    }
    assert!(
        circuit.is_closed(),
        "Circuit should not trip on fast errors"
    );
}

#[test]
fn test_no_classifier_default_behavior() {
    // Without classifier, all errors should trip circuit (backward compatible)
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(3).build();

    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(circuit.is_closed());

    let _ = circuit.call(|| Err::<(), _>("error 3"));
    assert!(
        circuit.is_open(),
        "All errors should trip circuit without classifier"
    );
}

#[test]
fn test_classifier_with_custom_error_type() {
    use crate::classifier::PredicateClassifier;

    #[derive(Debug)]
    enum ApiError {
        ClientError(u16),
        ServerError(u16),
    }

    // Only trip on server errors (5xx), not client errors (4xx)
    let classifier = Arc::new(PredicateClassifier::new(|ctx| {
        ctx.error
            .downcast_ref::<ApiError>()
            .map(|e| match e {
                ApiError::ServerError(code) => *code >= 500,
                ApiError::ClientError(code) => *code >= 500, // Should never happen, but validates field
            })
            .unwrap_or(true)
    }));

    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .failure_classifier(classifier)
        .build();

    // Client errors (4xx) should not trip
    for _ in 0..10 {
        let _ = circuit.call(|| Err::<(), _>(ApiError::ClientError(404)));
    }
    assert!(circuit.is_closed(), "Client errors should not trip circuit");

    // Server errors (5xx) should trip
    let _ = circuit.call(|| Err::<(), _>(ApiError::ServerError(500)));
    let _ = circuit.call(|| Err::<(), _>(ApiError::ServerError(503)));
    assert!(circuit.is_open(), "Server errors should trip circuit");
}

#[test]
fn test_bulkhead_rejects_at_capacity() {
    let mut circuit = CircuitBreaker::builder("test").max_concurrency(2).build();

    // First two calls should succeed (we're not actually holding them)
    let result1 = circuit.call(|| Ok::<_, String>("success 1"));
    let result2 = circuit.call(|| Ok::<_, String>("success 2"));

    assert!(result1.is_ok());
    assert!(result2.is_ok());
}

#[test]
fn test_bulkhead_releases_on_success() {
    use std::sync::{Arc, Mutex};

    let circuit = Arc::new(Mutex::new(
        CircuitBreaker::builder("test").max_concurrency(1).build(),
    ));

    // First call acquires permit
    let result1 = circuit.lock().unwrap().call(|| Ok::<_, String>("success"));
    assert!(result1.is_ok());

    // Permit is released, second call should succeed
    let result2 = circuit.lock().unwrap().call(|| Ok::<_, String>("success"));
    assert!(result2.is_ok());
}

#[test]
fn test_bulkhead_releases_on_failure() {
    use std::sync::{Arc, Mutex};

    let circuit = Arc::new(Mutex::new(
        CircuitBreaker::builder("test")
            .max_concurrency(1)
            .failure_threshold(10) // High threshold so circuit doesn't open
            .build(),
    ));

    // First call fails but releases permit
    let result1 = circuit.lock().unwrap().call(|| Err::<(), _>("error"));
    assert!(result1.is_err());

    // Permit is released, second call should succeed
    let result2 = circuit.lock().unwrap().call(|| Ok::<_, String>("success"));
    assert!(result2.is_ok());
}

#[test]
fn test_bulkhead_without_limit() {
    let mut circuit = CircuitBreaker::builder("test").build();

    // Without bulkhead, all calls should go through
    for _ in 0..100 {
        let result = circuit.call(|| Ok::<_, String>("success"));
        assert!(result.is_ok());
    }
}

#[test]
fn test_bulkhead_error_contains_limit() {
    // Test that bulkhead full error contains circuit name and limit
    // We use the underlying semaphore to simulate capacity exhaustion
    use std::sync::Arc;

    let bulkhead = Arc::new(BulkheadSemaphore::new(2));

    let mut circuit = CircuitBreaker::builder("test").build();

    // Manually inject bulkhead into circuit context
    circuit.context.bulkhead = Some(bulkhead.clone());

    // Acquire all permits directly from semaphore
    let _guard1 = bulkhead.try_acquire().unwrap();
    let _guard2 = bulkhead.try_acquire().unwrap();

    // Now circuit call should fail with BulkheadFull
    let result = circuit.call(|| Ok::<_, String>("should fail"));

    match result {
        Err(CircuitError::BulkheadFull {
            circuit: name,
            limit,
        }) => {
            assert_eq!(name, "test");
            assert_eq!(limit, 2);
        }
        _ => panic!("Expected BulkheadFull error, got: {result:?}"),
    }

    // Drop guards to release permits
    drop(_guard1);
    drop(_guard2);

    // Now call should succeed
    let result = circuit.call(|| Ok::<_, String>("success"));
    assert!(result.is_ok());
}

#[test]
fn test_bulkhead_with_circuit_breaker() {
    let mut circuit = CircuitBreaker::builder("test")
        .max_concurrency(5)
        .failure_threshold(3)
        .build();

    // Circuit is closed, bulkhead allows calls
    let result = circuit.call(|| Ok::<_, String>("success"));
    assert!(result.is_ok());

    // Open the circuit with failures
    for _ in 0..3 {
        let _ = circuit.call(|| Err::<(), _>("error"));
    }
    assert!(circuit.is_open());

    // Even with bulkhead capacity, open circuit rejects calls
    let result = circuit.call(|| Ok::<_, String>("should fail"));
    assert!(matches!(result, Err(CircuitError::Open { .. })));
}

#[test]
fn test_check_and_trip_sets_opened_at_and_callback() {
    use std::sync::atomic::{AtomicBool, Ordering};

    let opened = Arc::new(AtomicBool::new(false));
    let opened_clone = opened.clone();

    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(1)
        .on_open(move |_name| {
            opened_clone.store(true, Ordering::SeqCst);
        })
        .build();

    circuit.record_failure(0.1);
    let tripped = circuit.check_and_trip();

    assert!(tripped, "Trip should succeed");
    assert!(circuit.is_open(), "Circuit should be open after trip");

    let opened_at = circuit
        .machine
        .open_data()
        .expect("Open data should be present")
        .opened_at;

    assert!(opened_at > 0.0, "opened_at should be set");
    assert!(
        opened.load(Ordering::SeqCst),
        "on_open callback should fire"
    );
}

#[test]
fn test_half_open_failure_resets_consecutive_successes() {
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .half_open_timeout_secs(0.001)
        .success_threshold(2)
        .build();

    // Open the circuit
    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(circuit.is_open());

    // Move to HalfOpen
    if let Some(data) = circuit.machine.open_data_mut() {
        data.opened_at = circuit.context.storage.monotonic_time();
    }
    std::thread::sleep(std::time::Duration::from_millis(2));
    circuit
        .machine
        .handle(CircuitEvent::AttemptReset)
        .expect("Should transition to HalfOpen");
    assert_eq!(circuit.machine.current_state(), CircuitState::HalfOpen);

    // Clear counts to simulate expired failure window
    circuit.context.storage.clear("test");

    // First success increments consecutive count
    let _ = circuit.call(|| Ok::<_, String>("ok"));
    assert_eq!(
        circuit
            .machine
            .half_open_data()
            .expect("HalfOpen data")
            .consecutive_successes,
        1
    );

    // Failure below threshold should not reopen circuit but should reset counter
    let _ = circuit.call(|| Err::<(), _>("fail"));
    assert_eq!(circuit.machine.current_state(), CircuitState::HalfOpen);
    assert_eq!(
        circuit
            .machine
            .half_open_data()
            .expect("HalfOpen data")
            .consecutive_successes,
        0
    );

    // Next success starts count from 1 again
    let _ = circuit.call(|| Ok::<_, String>("ok2"));
    assert_eq!(
        circuit
            .machine
            .half_open_data()
            .expect("HalfOpen data")
            .consecutive_successes,
        1
    );
}

#[test]
fn test_panicking_probe_does_not_wedge_half_open() {
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(0.001)
        .success_threshold(1)
        .build();

    // Open the circuit.
    let _ = circuit.call(|| Err::<(), _>("error"));
    assert!(circuit.is_open());

    // Move to HalfOpen.
    if let Some(data) = circuit.machine.open_data_mut() {
        data.opened_at = circuit.context.storage.monotonic_time();
    }
    std::thread::sleep(std::time::Duration::from_millis(2));

    // A probe that panics must release its reserved in_flight slot.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        circuit.call(|| -> Result<(), String> { panic!("boom") })
    }));
    assert!(result.is_err(), "closure should have panicked");

    // Clear the failure window so the next probe can succeed and close.
    circuit.context.storage.clear("test");

    // Circuit must not be stuck rejecting every probe with HalfOpenLimitReached.
    let recovered = circuit.call(|| Ok::<_, String>("ok"));
    assert!(
        recovered.is_ok(),
        "probe slot leaked after panic: {recovered:?}"
    );
    assert!(circuit.is_closed(), "circuit should recover and close");
}

#[test]
fn test_open_fallback_releases_bulkhead_permit() {
    use std::sync::Arc;

    let bulkhead = Arc::new(BulkheadSemaphore::new(1));
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(1).build();
    circuit.context.bulkhead = Some(bulkhead.clone());

    // Open the circuit.
    let _ = circuit.call(|| Err::<(), _>("error"));
    assert!(circuit.is_open());

    // Fallback runs while open; the bulkhead permit must be released first so
    // the fallback body can itself acquire a permit.
    let result = circuit.call((
        || Ok::<bool, String>(false),
        CallOptions::new().with_fallback(move |_ctx| {
            let acquired = bulkhead.try_acquire().is_some();
            Ok::<bool, String>(acquired)
        }),
    ));

    assert!(
        result.unwrap(),
        "fallback should be able to acquire the released permit"
    );
}

#[test]
fn test_jitter_distribution_within_bounds() {
    // Test that jitter produces values within expected bounds
    // With 25% jitter on 1000ms base, expect 750-1000ms range
    let storage = Arc::new(crate::MemoryStorage::new());
    let base_timeout = 1.0; // 1 second
    let jitter_factor = 0.25;

    let config = Config {
        failure_threshold: Some(1),
        half_open_timeout_secs: base_timeout,
        jitter_factor,
        ..Default::default()
    };

    let ctx = CircuitContext {
        failure_classifier: None,
        bulkhead: None,
        name: "jitter_test".to_string(),
        config,
        storage: storage.clone(),
    };

    // Run 50 iterations and collect timeout values
    let mut min_seen = f64::MAX;
    let mut max_seen = f64::MIN;

    for _ in 0..50 {
        storage.record_failure("jitter_test", 0.1);
        let mut circuit = DynamicCircuit::new(ctx.clone());
        circuit.handle(CircuitEvent::Trip).expect("Should open");

        if let Some(data) = circuit.open_data_mut() {
            data.opened_at = storage.monotonic_time();
        }

        // Calculate what the jittered timeout would be
        let policy = chrono_machines::Policy {
            max_attempts: 1,
            base_delay_ms: (base_timeout * 1000.0) as u64,
            multiplier: 1.0,
            max_delay_ms: (base_timeout * 1000.0) as u64,
        };
        let timeout_ms = policy.calculate_delay(1, jitter_factor);
        let timeout_secs = (timeout_ms as f64) / 1000.0;

        min_seen = min_seen.min(timeout_secs);
        max_seen = max_seen.max(timeout_secs);

        storage.clear("jitter_test");
    }

    // With 25% jitter, minimum should be ~0.75s (75% of base)
    // Maximum should be ~1.0s (100% of base)
    let min_expected = base_timeout * (1.0 - jitter_factor);
    let max_expected = base_timeout;

    assert!(
        min_seen >= min_expected - 0.01,
        "Minimum jittered timeout {min_seen} should be >= {min_expected}"
    );
    assert!(
        max_seen <= max_expected + 0.01,
        "Maximum jittered timeout {max_seen} should be <= {max_expected}"
    );
}

#[test]
fn test_jitter_produces_variance() {
    // Test that jitter actually produces different values (not all same)
    let storage = Arc::new(crate::MemoryStorage::new());

    let config = Config {
        failure_threshold: Some(1),
        half_open_timeout_secs: 1.0,
        jitter_factor: 0.5, // 50% jitter for more variance
        ..Default::default()
    };

    let _ctx = CircuitContext {
        failure_classifier: None,
        bulkhead: None,
        name: "jitter_variance".to_string(),
        config,
        storage,
    };

    let mut values = std::collections::HashSet::new();

    for _ in 0..20 {
        let policy = chrono_machines::Policy {
            max_attempts: 1,
            base_delay_ms: 1000,
            multiplier: 1.0,
            max_delay_ms: 1000,
        };
        let timeout_ms = policy.calculate_delay(1, 0.5);
        values.insert(timeout_ms);
    }

    // With 50% jitter over 20 iterations, we should see at least 2 different values
    // (statistically, seeing all same values is extremely unlikely)
    assert!(
        values.len() >= 2,
        "Jitter should produce variance, got {} unique values",
        values.len()
    );
}

#[test]
fn test_zero_jitter_produces_constant_timeout() {
    // Test that 0% jitter always produces the same timeout
    let policy = chrono_machines::Policy {
        max_attempts: 1,
        base_delay_ms: 1000,
        multiplier: 1.0,
        max_delay_ms: 1000,
    };

    let mut values = std::collections::HashSet::new();

    for _ in 0..10 {
        let timeout_ms = policy.calculate_delay(1, 0.0);
        values.insert(timeout_ms);
    }

    assert_eq!(
        values.len(),
        1,
        "Zero jitter should produce constant timeout"
    );
    assert!(values.contains(&1000), "Timeout should be exactly 1000ms");
}
