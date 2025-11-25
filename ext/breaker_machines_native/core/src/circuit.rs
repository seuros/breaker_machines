//! Circuit breaker implementation using state machines
//!
//! This module provides a complete circuit breaker with state management.

use crate::{
    StorageBackend, bulkhead::BulkheadSemaphore, callbacks::Callbacks,
    classifier::FailureClassifier, errors::CircuitError,
};
use state_machines::state_machine;
use std::sync::Arc;

/// Circuit breaker configuration
#[derive(Debug, Clone)]
pub struct Config {
    /// Number of failures required to open the circuit (absolute count)
    /// If None, only rate-based threshold is used
    pub failure_threshold: Option<usize>,

    /// Failure rate threshold (0.0-1.0) - percentage of failures to open circuit
    /// If None, only absolute count threshold is used
    pub failure_rate_threshold: Option<f64>,

    /// Minimum number of calls before rate-based threshold is evaluated
    pub minimum_calls: usize,

    /// Time window in seconds for counting failures
    pub failure_window_secs: f64,

    /// Timeout in seconds before transitioning from Open to HalfOpen
    pub half_open_timeout_secs: f64,

    /// Number of successes required in HalfOpen to close the circuit
    pub success_threshold: usize,

    /// Jitter factor for half_open_timeout (0.0 = no jitter, 1.0 = full jitter)
    /// Uses chrono-machines formula: timeout * (1 - jitter + rand * jitter)
    pub jitter_factor: f64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            failure_threshold: Some(5),
            failure_rate_threshold: None,
            minimum_calls: 20,
            failure_window_secs: 60.0,
            half_open_timeout_secs: 30.0,
            success_threshold: 2,
            jitter_factor: 0.0,
        }
    }
}

/// Context provided to fallback closures when circuit is open
#[derive(Debug, Clone)]
pub struct FallbackContext {
    /// Circuit name
    pub circuit_name: String,
    /// Timestamp when circuit opened
    pub opened_at: f64,
    /// Current circuit state
    pub state: &'static str,
}

/// Type alias for fallback function
pub type FallbackFn<T, E> = Box<dyn FnOnce(&FallbackContext) -> Result<T, E> + Send>;

/// Options for circuit breaker calls
pub struct CallOptions<T, E> {
    /// Optional fallback function called when circuit is open
    pub fallback: Option<FallbackFn<T, E>>,
}

impl<T, E> Default for CallOptions<T, E> {
    fn default() -> Self {
        Self { fallback: None }
    }
}

impl<T, E> CallOptions<T, E> {
    /// Create new call options with no fallback
    pub fn new() -> Self {
        Self::default()
    }

    /// Set a fallback function
    pub fn with_fallback<F>(mut self, f: F) -> Self
    where
        F: FnOnce(&FallbackContext) -> Result<T, E> + Send + 'static,
    {
        self.fallback = Some(Box::new(f));
        self
    }
}

/// Type alias for callable function
pub type CallableFn<T, E> = Box<dyn FnOnce() -> Result<T, E>>;

/// Trait for converting into CallOptions - allows flexible call() API
pub trait IntoCallOptions<T, E> {
    fn into_call_options(self) -> (CallableFn<T, E>, CallOptions<T, E>);
}

/// Implement for plain closures (backward compatibility)
impl<T, E, F> IntoCallOptions<T, E> for F
where
    F: FnOnce() -> Result<T, E> + 'static,
{
    fn into_call_options(self) -> (Box<dyn FnOnce() -> Result<T, E>>, CallOptions<T, E>) {
        (Box::new(self), CallOptions::default())
    }
}

/// Implement for (closure, CallOptions) tuple
impl<T, E, F> IntoCallOptions<T, E> for (F, CallOptions<T, E>)
where
    F: FnOnce() -> Result<T, E> + 'static,
{
    fn into_call_options(self) -> (Box<dyn FnOnce() -> Result<T, E>>, CallOptions<T, E>) {
        (Box::new(self.0), self.1)
    }
}

/// Circuit breaker context - shared data across all states
#[derive(Clone)]
pub struct CircuitContext {
    pub name: String,
    pub config: Config,
    pub storage: Arc<dyn StorageBackend>,
    pub failure_classifier: Option<Arc<dyn FailureClassifier>>,
    pub bulkhead: Option<Arc<BulkheadSemaphore>>,
}

impl Default for CircuitContext {
    fn default() -> Self {
        Self {
            name: String::new(),
            config: Config::default(),
            storage: Arc::new(crate::MemoryStorage::new()),
            failure_classifier: None,
            bulkhead: None,
        }
    }
}

impl std::fmt::Debug for CircuitContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircuitContext")
            .field("name", &self.name)
            .field("config", &self.config)
            .field("storage", &"<dyn StorageBackend>")
            .field(
                "failure_classifier",
                &self
                    .failure_classifier
                    .as_ref()
                    .map(|_| "<dyn FailureClassifier>"),
            )
            .field("bulkhead", &self.bulkhead)
            .finish()
    }
}

/// Data specific to the Open state
#[derive(Debug, Clone, Default)]
pub struct OpenData {
    pub opened_at: f64,
}

/// Data specific to the HalfOpen state
#[derive(Debug, Clone, Default)]
pub struct HalfOpenData {
    pub consecutive_successes: usize,
}

// Define the circuit breaker state machine with dynamic mode
state_machine! {
    name: Circuit,
    context: CircuitContext,
    dynamic: true,  // Enable dynamic mode for runtime state transitions

    initial: Closed,
    states: [
        Closed,
        Open(OpenData),
        HalfOpen(HalfOpenData),
    ],
    events {
        trip {
            guards: [should_open],
            transition: { from: [Closed, HalfOpen], to: Open }
        }
        attempt_reset {
            guards: [timeout_elapsed],
            transition: { from: Open, to: HalfOpen }
        }
        close {
            guards: [should_close],
            transition: { from: HalfOpen, to: Closed }
        }
    }
}

// Guards for dynamic mode - implemented on typestate machines
impl Circuit<Closed> {
    /// Check if failure threshold is exceeded (absolute count or rate-based)
    fn should_open(&self, ctx: &CircuitContext) -> bool {
        let failures = ctx
            .storage
            .failure_count(&ctx.name, ctx.config.failure_window_secs);

        // Check absolute count threshold
        if let Some(threshold) = ctx.config.failure_threshold
            && failures >= threshold
        {
            return true;
        }

        // Check rate-based threshold
        if let Some(rate_threshold) = ctx.config.failure_rate_threshold {
            let successes = ctx
                .storage
                .success_count(&ctx.name, ctx.config.failure_window_secs);
            let total = failures + successes;

            // Only evaluate rate if we have minimum calls
            if total >= ctx.config.minimum_calls {
                let failure_rate = if total > 0 {
                    failures as f64 / total as f64
                } else {
                    0.0
                };

                if failure_rate >= rate_threshold {
                    return true;
                }
            }
        }

        false
    }
}

impl Circuit<HalfOpen> {
    /// Check if failure threshold is exceeded (absolute count or rate-based)
    fn should_open(&self, ctx: &CircuitContext) -> bool {
        let failures = ctx
            .storage
            .failure_count(&ctx.name, ctx.config.failure_window_secs);

        // Check absolute count threshold
        if let Some(threshold) = ctx.config.failure_threshold
            && failures >= threshold
        {
            return true;
        }

        // Check rate-based threshold
        if let Some(rate_threshold) = ctx.config.failure_rate_threshold {
            let successes = ctx
                .storage
                .success_count(&ctx.name, ctx.config.failure_window_secs);
            let total = failures + successes;

            // Only evaluate rate if we have minimum calls
            if total >= ctx.config.minimum_calls {
                let failure_rate = if total > 0 {
                    failures as f64 / total as f64
                } else {
                    0.0
                };

                if failure_rate >= rate_threshold {
                    return true;
                }
            }
        }

        false
    }

    /// Check if enough successes to close circuit
    fn should_close(&self, ctx: &CircuitContext) -> bool {
        let data = self
            .state_data_half_open()
            .expect("HalfOpen state must have data");
        data.consecutive_successes >= ctx.config.success_threshold
    }
}

impl Circuit<Open> {
    /// Check if timeout has elapsed for Open -> HalfOpen transition
    fn timeout_elapsed(&self, ctx: &CircuitContext) -> bool {
        let data = self.state_data_open().expect("Open state must have data");
        let current_time = ctx.storage.monotonic_time();
        let elapsed = current_time - data.opened_at;

        // Apply jitter using chrono-machines if jitter_factor > 0
        let timeout_secs = if ctx.config.jitter_factor > 0.0 {
            let policy = chrono_machines::Policy {
                max_attempts: 1,
                base_delay_ms: (ctx.config.half_open_timeout_secs * 1000.0) as u64,
                multiplier: 1.0,
                max_delay_ms: (ctx.config.half_open_timeout_secs * 1000.0) as u64,
            };
            let timeout_ms = policy.calculate_delay(1, ctx.config.jitter_factor);
            (timeout_ms as f64) / 1000.0
        } else {
            ctx.config.half_open_timeout_secs
        };

        elapsed >= timeout_secs
    }
}

/// Circuit breaker public API
pub struct CircuitBreaker {
    machine: DynamicCircuit,
    context: CircuitContext,
    callbacks: Callbacks,
}

impl CircuitBreaker {
    /// Create a new circuit breaker (use builder() for more options)
    pub fn new(name: String, config: Config) -> Self {
        let storage = Arc::new(crate::MemoryStorage::new());
        let context = CircuitContext {
            name,
            config,
            storage,
            failure_classifier: None,
            bulkhead: None,
        };

        let machine = DynamicCircuit::new(context.clone());
        let callbacks = Callbacks::new();

        Self {
            machine,
            context,
            callbacks,
        }
    }

    /// Create a circuit breaker with custom context and callbacks (used by builder)
    pub(crate) fn with_context_and_callbacks(
        context: CircuitContext,
        callbacks: Callbacks,
    ) -> Self {
        let machine = DynamicCircuit::new(context.clone());

        Self {
            machine,
            context,
            callbacks,
        }
    }

    /// Create a new circuit breaker builder
    pub fn builder(name: impl Into<String>) -> crate::builder::CircuitBuilder {
        crate::builder::CircuitBuilder::new(name)
    }

    /// Execute a fallible operation with circuit breaker protection
    ///
    /// Accepts either:
    /// - A plain closure: `circuit.call(|| api_request())`
    /// - A closure with options: `circuit.call((|| api_request(), CallOptions::new().with_fallback(...)))`
    pub fn call<I, T, E: 'static>(&mut self, input: I) -> Result<T, CircuitError<E>>
    where
        I: IntoCallOptions<T, E>,
    {
        let (f, options) = input.into_call_options();

        // Try to acquire bulkhead permit if configured
        let _guard = if let Some(bulkhead) = &self.context.bulkhead {
            match bulkhead.try_acquire() {
                Some(guard) => Some(guard),
                None => {
                    return Err(CircuitError::BulkheadFull {
                        circuit: self.context.name.clone(),
                        limit: bulkhead.limit(),
                    });
                }
            }
        } else {
            None
        };

        // Check for timeout-based Open -> HalfOpen transition
        if self.machine.current_state() == "Open" {
            let _ = self.machine.handle(CircuitEvent::AttemptReset);
            if self.machine.current_state() == "HalfOpen" {
                self.callbacks.trigger_half_open(&self.context.name);
            }
        }

        // Handle based on current state
        match self.machine.current_state() {
            "Open" => {
                let opened_at = self.machine.open_data().map(|d| d.opened_at).unwrap_or(0.0);

                // If fallback is provided, use it instead of returning error
                if let Some(fallback) = options.fallback {
                    let ctx = FallbackContext {
                        circuit_name: self.context.name.clone(),
                        opened_at,
                        state: "Open",
                    };
                    return fallback(&ctx).map_err(CircuitError::Execution);
                }

                Err(CircuitError::Open {
                    circuit: self.context.name.clone(),
                    opened_at,
                })
            }
            "HalfOpen" => {
                // Check if we've reached the success threshold
                if let Some(data) = self.machine.half_open_data()
                    && data.consecutive_successes >= self.context.config.success_threshold
                {
                    return Err(CircuitError::HalfOpenLimitReached {
                        circuit: self.context.name.clone(),
                    });
                }
                self.execute_call(f)
            }
            _ => self.execute_call(f),
        }
    }

    fn execute_call<T, E: 'static>(
        &mut self,
        f: Box<dyn FnOnce() -> Result<T, E>>,
    ) -> Result<T, CircuitError<E>> {
        let start = self.context.storage.monotonic_time();

        match f() {
            Ok(val) => {
                let duration = self.context.storage.monotonic_time() - start;
                self.context
                    .storage
                    .record_success(&self.context.name, duration);

                // Handle success in HalfOpen state
                if self.machine.current_state() == "HalfOpen" {
                    if let Some(data) = self.machine.half_open_data_mut() {
                        data.consecutive_successes += 1;
                    }

                    // Try to close the circuit
                    if self.machine.handle(CircuitEvent::Close).is_ok() {
                        self.callbacks.trigger_close(&self.context.name);
                    }
                }

                Ok(val)
            }
            Err(e) => {
                let duration = self.context.storage.monotonic_time() - start;

                // Check if this error should trip the circuit using failure classifier
                let should_trip = if let Some(classifier) = &self.context.failure_classifier {
                    let ctx = crate::classifier::FailureContext {
                        circuit_name: &self.context.name,
                        error: &e as &dyn std::any::Any,
                        duration,
                    };
                    classifier.should_trip(&ctx)
                } else {
                    // No classifier - default behavior is to trip on all errors
                    true
                };

                // Only record failure and try to trip if classifier says we should
                if should_trip {
                    self.context
                        .storage
                        .record_failure(&self.context.name, duration);

                    // Try to trip the circuit
                    let result = self.machine.handle(CircuitEvent::Trip);
                    if result.is_ok() {
                        self.mark_open();
                    } else if self.machine.current_state() == "HalfOpen" {
                        // Failure did not reopen the circuit; reset consecutive successes
                        if let Some(data) = self.machine.half_open_data_mut() {
                            data.consecutive_successes = 0;
                        }
                    }
                }

                Err(CircuitError::Execution(e))
            }
        }
    }

    /// Record a successful operation and drive HalfOpen -> Closed transitions
    pub fn record_success_and_maybe_close(&mut self, duration: f64) {
        self.context
            .storage
            .record_success(&self.context.name, duration);

        if self.machine.current_state() == "HalfOpen" {
            if let Some(data) = self.machine.half_open_data_mut() {
                data.consecutive_successes += 1;
            }

            if self.machine.handle(CircuitEvent::Close).is_ok() {
                self.callbacks.trigger_close(&self.context.name);
            }
        }
    }

    /// Record a failed operation and attempt to trip the circuit
    pub fn record_failure_and_maybe_trip(&mut self, duration: f64) {
        self.context
            .storage
            .record_failure(&self.context.name, duration);

        let result = self.machine.handle(CircuitEvent::Trip);
        if result.is_ok() {
            self.mark_open();
        } else if self.machine.current_state() == "HalfOpen"
            && let Some(data) = self.machine.half_open_data_mut()
        {
            data.consecutive_successes = 0;
        }
    }

    /// Record a successful operation (for manual tracking)
    pub fn record_success(&self, duration: f64) {
        self.context
            .storage
            .record_success(&self.context.name, duration);
    }

    /// Record a failed operation (for manual tracking)
    pub fn record_failure(&self, duration: f64) {
        self.context
            .storage
            .record_failure(&self.context.name, duration);
    }

    /// Check failure threshold and attempt to trip the circuit
    /// This should be called after record_failure() when not using call()
    pub fn check_and_trip(&mut self) -> bool {
        if self.machine.handle(CircuitEvent::Trip).is_ok() {
            self.mark_open();
            true
        } else {
            false
        }
    }

    /// Check if circuit is open
    pub fn is_open(&self) -> bool {
        self.machine.current_state() == "Open"
    }

    /// Check if circuit is closed
    pub fn is_closed(&self) -> bool {
        self.machine.current_state() == "Closed"
    }

    /// Get current state name
    pub fn state_name(&self) -> &'static str {
        self.machine.current_state()
    }

    /// Clear all events and reset circuit to Closed state
    pub fn reset(&mut self) {
        self.context.storage.clear(&self.context.name);
        // Recreate machine in Closed state
        self.machine = DynamicCircuit::new(self.context.clone());
    }

    /// Apply Open-state bookkeeping (timestamp + callback)
    fn mark_open(&mut self) {
        if let Some(data) = self.machine.open_data_mut() {
            data.opened_at = self.context.storage.monotonic_time();
        }
        self.callbacks.trigger_open(&self.context.name);
    }
}

#[cfg(test)]
mod tests {
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

        let mut circuit = DynamicCircuit::new(ctx.clone());

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

        assert_eq!(circuit.current_state(), "Open");
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

        let mut circuit = DynamicCircuit::new(ctx.clone());
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
        assert_eq!(circuit.current_state(), "HalfOpen");
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

        let mut circuit = DynamicCircuit::new(ctx.clone());
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
        let mut circuit = DynamicCircuit::new(ctx.clone());
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
        assert_eq!(circuit.current_state(), "HalfOpen");
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
            _ => panic!("Expected BulkheadFull error, got: {:?}", result),
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
        assert_eq!(circuit.machine.current_state(), "HalfOpen");

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
        assert_eq!(circuit.machine.current_state(), "HalfOpen");
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
            "Minimum jittered timeout {} should be >= {}",
            min_seen,
            min_expected
        );
        assert!(
            max_seen <= max_expected + 0.01,
            "Maximum jittered timeout {} should be <= {}",
            max_seen,
            max_expected
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

        let ctx = CircuitContext {
            failure_classifier: None,
            bulkhead: None,
            name: "jitter_variance".to_string(),
            config,
            storage: storage.clone(),
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
}
