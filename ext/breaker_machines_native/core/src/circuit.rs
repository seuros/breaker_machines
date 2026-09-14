//! Circuit breaker implementation using state machines
//!
//! This module provides a complete circuit breaker with state management.

use crate::{
    StorageBackend, bulkhead::BulkheadSemaphore, callbacks::Callbacks,
    classifier::FailureClassifier, errors::CircuitError,
};
use alloc::boxed::Box;
use alloc::string::String;
use alloc::sync::Arc;
use state_machines::state_machine;

/// Circuit breaker configuration
#[derive(Debug, Clone, Copy)]
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

    /// Maximum lifetime of a distributed half-open probe lease. A different
    /// node may take over after this duration if the elected caller crashes or
    /// its call future is cancelled.
    pub probe_timeout_secs: f64,

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
            probe_timeout_secs: 30.0,
            jitter_factor: 0.0,
        }
    }
}

impl Config {
    pub(crate) fn half_open_delay_secs(&self) -> f64 {
        if self.jitter_factor > 0.0 {
            let policy = chrono_machines::Policy {
                max_attempts: 1,
                base_delay_ms: (self.half_open_timeout_secs * 1000.0) as u64,
                multiplier: 1.0,
                max_delay_ms: (self.half_open_timeout_secs * 1000.0) as u64,
            };
            #[cfg(feature = "std")]
            let timeout_ms = policy.calculate_delay(1, self.jitter_factor);
            #[cfg(not(feature = "std"))]
            let timeout_ms = policy.base_delay_ms;
            (timeout_ms as f64) / 1000.0
        } else {
            self.half_open_timeout_secs
        }
    }
}

/// Context provided to fallback closures when circuit is open
#[derive(Debug, Clone)]
pub struct FallbackContext {
    /// Circuit name
    pub circuit_name: Arc<str>,
    /// Timestamp when circuit opened
    pub opened_at: f64,
    /// Current circuit state
    pub state: &'static str,
}

impl FallbackContext {
    /// Convert this context into the rejection error for an open circuit.
    pub(crate) fn into_open_error<E>(self) -> CircuitError<E> {
        CircuitError::Open {
            circuit: self.circuit_name,
            opened_at: self.opened_at,
        }
    }
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

    /// Resolve an open-circuit gate: run the fallback if present, otherwise
    /// return the rejection error.
    pub(crate) fn resolve_open(self, context: FallbackContext) -> Result<T, CircuitError<E>> {
        match self.fallback {
            Some(fallback) => fallback(&context).map_err(CircuitError::Execution),
            None => Err(context.into_open_error()),
        }
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

pub(crate) struct CallPermit {
    _bulkhead: Option<crate::BulkheadGuard>,
    half_open_probe: bool,
    state_epoch: u64,
}

impl CallPermit {
    pub(crate) fn half_open_probe(&self) -> bool {
        self.half_open_probe
    }

    pub(crate) fn state_epoch(&self) -> u64 {
        self.state_epoch
    }
}

pub(crate) enum CallGate {
    Execute(CallPermit),
    Open {
        _permit: CallPermit,
        context: FallbackContext,
    },
}

/// RAII guard that releases a reserved half-open probe slot if the protected
/// operation panics. On the normal path `complete_call` performs the release,
/// so the guard is disarmed before it runs. Without this, a panicking probe
/// would leak `in_flight` and wedge the circuit in HalfOpen forever.
struct HalfOpenProbeGuard<'a> {
    circuit: &'a mut CircuitBreaker,
    armed: bool,
    state_epoch: u64,
}

impl HalfOpenProbeGuard<'_> {
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for HalfOpenProbeGuard<'_> {
    fn drop(&mut self) {
        if self.armed {
            self.circuit.release_half_open_probe(self.state_epoch);
        }
    }
}

/// Circuit breaker context - shared data across all states
#[derive(Clone)]
pub struct CircuitContext {
    pub name: Arc<str>,
    pub config: Config,
    pub storage: Arc<dyn StorageBackend>,
    pub failure_classifier: Option<Arc<dyn FailureClassifier>>,
    pub bulkhead: Option<Arc<BulkheadSemaphore>>,
}

impl Default for CircuitContext {
    fn default() -> Self {
        Self {
            name: Arc::from(""),
            config: Config::default(),
            storage: Arc::new(crate::MemoryStorage::new()),
            failure_classifier: None,
            bulkhead: None,
        }
    }
}

impl core::fmt::Debug for CircuitContext {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
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
    pub in_flight: usize,
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

/// Check thresholds against observed counts (absolute count or rate-based).
///
/// The success count is queried lazily because it is only needed when a rate
/// threshold is configured. Shared by the local circuit guards and the
/// in-memory distributed store.
pub(crate) fn thresholds_exceeded(
    failures: usize,
    successes: impl FnOnce() -> usize,
    failure_threshold: Option<usize>,
    failure_rate_threshold: Option<f64>,
    minimum_calls: usize,
) -> bool {
    if let Some(threshold) = failure_threshold
        && failures >= threshold
    {
        return true;
    }

    if let Some(rate_threshold) = failure_rate_threshold {
        let total = failures + successes();

        // Only evaluate rate if we have minimum calls
        if total >= minimum_calls && total > 0 {
            return failures as f64 / total as f64 >= rate_threshold;
        }
    }

    false
}

// Guards for dynamic mode - implemented on typestate machines
impl<S> Circuit<S> {
    /// Check if failure threshold is exceeded (absolute count or rate-based).
    ///
    /// Used by the `trip` guard for both the Closed and HalfOpen typestates;
    /// the decision depends only on the context (storage counters + config),
    /// not on the current state data.
    fn should_open(&self, ctx: &CircuitContext) -> bool {
        let window = ctx.config.failure_window_secs;
        thresholds_exceeded(
            ctx.storage.failure_count(&ctx.name, window),
            || ctx.storage.success_count(&ctx.name, window),
            ctx.config.failure_threshold,
            ctx.config.failure_rate_threshold,
            ctx.config.minimum_calls,
        )
    }
}

impl Circuit<HalfOpen> {
    /// Check if enough successes to close circuit
    fn should_close(&self, ctx: &CircuitContext) -> bool {
        let Some(data) = self.state_data_half_open() else {
            unreachable!("HalfOpen typestate always carries HalfOpenData");
        };
        data.consecutive_successes >= ctx.config.success_threshold
    }
}

impl Circuit<Open> {
    /// Check if timeout has elapsed for Open -> HalfOpen transition
    fn timeout_elapsed(&self, ctx: &CircuitContext) -> bool {
        let Some(data) = self.state_data_open() else {
            unreachable!("Open typestate always carries OpenData");
        };
        let current_time = ctx.storage.monotonic_time();
        let elapsed = current_time - data.opened_at;

        let timeout_secs = ctx.config.half_open_delay_secs();

        elapsed >= timeout_secs
    }
}

/// Circuit breaker public API
pub struct CircuitBreaker {
    machine: DynamicCircuit,
    context: CircuitContext,
    callbacks: Callbacks,
    state_epoch: u64,
}

impl CircuitBreaker {
    /// Create a new circuit breaker (use builder() for more options)
    pub fn new(name: String, config: Config) -> Self {
        let context = CircuitContext {
            name: name.into(),
            config,
            ..CircuitContext::default()
        };

        let machine = DynamicCircuit::new(context.clone());
        let callbacks = Callbacks::new();

        Self {
            machine,
            context,
            callbacks,
            state_epoch: 0,
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
            state_epoch: 0,
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

        match self.prepare_call()? {
            CallGate::Execute(permit) => self.execute_call(permit, f),
            CallGate::Open {
                _permit: permit,
                context,
            } => {
                // Release the bulkhead permit before the fallback runs so a slow
                // fallback doesn't occupy a concurrency slot (matches async path).
                drop(permit);
                options.resolve_open(context)
            }
        }
    }

    pub(crate) fn prepare_call<E>(&mut self) -> Result<CallGate, CircuitError<E>> {
        // Try to acquire bulkhead permit if configured
        let permit = if let Some(bulkhead) = &self.context.bulkhead {
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
        if self.machine.current_state() == CircuitState::Open {
            let _ = self.machine.handle(CircuitEvent::AttemptReset);
            if self.machine.current_state() == CircuitState::HalfOpen {
                self.advance_state_epoch();
                self.callbacks.trigger_half_open(&self.context.name);
            }
        }

        let mut permit = CallPermit {
            _bulkhead: permit,
            half_open_probe: false,
            state_epoch: self.state_epoch,
        };

        // Handle based on current state
        match self.machine.current_state() {
            CircuitState::Open => {
                let Some(data) = self.machine.open_data() else {
                    unreachable!("Open state always carries OpenData");
                };
                let opened_at = data.opened_at;

                Ok(CallGate::Open {
                    _permit: permit,
                    context: FallbackContext {
                        circuit_name: self.context.name.clone(),
                        opened_at,
                        state: "Open",
                    },
                })
            }
            CircuitState::HalfOpen => {
                // Check if we've reached the success threshold
                let Some(data) = self.machine.half_open_data_mut() else {
                    unreachable!("HalfOpen state always carries HalfOpenData");
                };
                let reserved_probes = data.consecutive_successes + data.in_flight;
                if reserved_probes >= self.context.config.success_threshold {
                    return Err(CircuitError::HalfOpenLimitReached {
                        circuit: self.context.name.clone(),
                    });
                }

                data.in_flight += 1;
                permit.half_open_probe = true;
                Ok(CallGate::Execute(permit))
            }
            _ => Ok(CallGate::Execute(permit)),
        }
    }

    fn execute_call<T, E: 'static>(
        &mut self,
        permit: CallPermit,
        f: Box<dyn FnOnce() -> Result<T, E>>,
    ) -> Result<T, CircuitError<E>> {
        let half_open_probe = permit.half_open_probe();
        let state_epoch = permit.state_epoch();
        let start = self.start_time();

        // Guard the reserved probe slot across `f()`: if it panics, the guard's
        // Drop releases it; on success we disarm and let `complete_call` release.
        let result = {
            let mut probe_guard = HalfOpenProbeGuard {
                circuit: self,
                armed: half_open_probe,
                state_epoch,
            };
            let result = f();
            probe_guard.disarm();
            result
        };

        let output = self.complete_call(start, result, half_open_probe, state_epoch);
        drop(permit);
        output
    }

    pub(crate) fn start_time(&self) -> f64 {
        self.context.storage.monotonic_time()
    }

    pub(crate) fn complete_call<T, E: 'static>(
        &mut self,
        start: f64,
        result: Result<T, E>,
        half_open_probe: bool,
        state_epoch: u64,
    ) -> Result<T, CircuitError<E>> {
        if half_open_probe {
            self.release_half_open_probe(state_epoch);
        }

        // Async calls may finish after the circuit has moved through one or
        // more states. Their outcomes still belong in the rolling metrics, but
        // they must not drive transitions for a newer state generation.
        let may_transition = state_epoch == self.state_epoch;

        match result {
            Ok(val) => {
                let duration = self.context.storage.monotonic_time() - start;
                self.record_success(duration);
                if may_transition {
                    self.maybe_close_after_success();
                }
                Ok(val)
            }
            Err(e) => {
                let duration = self.context.storage.monotonic_time() - start;

                // Check if this error should trip the circuit using failure classifier
                let should_trip = if let Some(classifier) = &self.context.failure_classifier {
                    let ctx = crate::classifier::FailureContext {
                        circuit_name: &self.context.name,
                        error: &e as &dyn core::any::Any,
                        duration,
                    };
                    classifier.should_trip(&ctx)
                } else {
                    // No classifier - default behavior is to trip on all errors
                    true
                };

                // Only record failure and try to trip if the classifier says we should
                if should_trip {
                    self.record_failure(duration);
                    if may_transition {
                        self.maybe_trip_after_failure();
                    }
                }

                Err(CircuitError::Execution(e))
            }
        }
    }

    pub(crate) fn release_half_open_probe(&mut self, state_epoch: u64) {
        if state_epoch == self.state_epoch {
            let Some(data) = self.machine.half_open_data_mut() else {
                unreachable!("probe epoch matches, so the machine is still HalfOpen");
            };
            data.in_flight -= 1;
        }
    }

    /// Record a successful operation and drive HalfOpen -> Closed transitions
    pub fn record_success_and_maybe_close(&mut self, duration: f64) {
        self.record_success(duration);
        self.maybe_close_after_success();
    }

    fn maybe_close_after_success(&mut self) {
        if self.machine.current_state() == CircuitState::HalfOpen {
            let Some(data) = self.machine.half_open_data_mut() else {
                unreachable!("HalfOpen state always carries HalfOpenData");
            };
            data.consecutive_successes += 1;

            if self.machine.handle(CircuitEvent::Close).is_ok() {
                self.advance_state_epoch();
                self.callbacks.trigger_close(&self.context.name);
            }
        }
    }

    /// Record a failed operation and attempt to trip the circuit
    pub fn record_failure_and_maybe_trip(&mut self, duration: f64) {
        self.record_failure(duration);
        self.maybe_trip_after_failure();
    }

    fn maybe_trip_after_failure(&mut self) {
        let result = self.machine.handle(CircuitEvent::Trip);
        if result.is_ok() {
            self.mark_open();
        } else if self.machine.current_state() == CircuitState::HalfOpen {
            let Some(data) = self.machine.half_open_data_mut() else {
                unreachable!("HalfOpen state always carries HalfOpenData");
            };
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
        self.machine.current_state() == CircuitState::Open
    }

    /// Check if circuit is closed
    pub fn is_closed(&self) -> bool {
        self.machine.current_state() == CircuitState::Closed
    }

    /// Get current state name
    pub fn state_name(&self) -> &'static str {
        self.machine.current_state().name()
    }

    /// Clear all events and reset circuit to Closed state
    pub fn reset(&mut self) {
        self.context.storage.clear(&self.context.name);
        // Recreate machine in Closed state
        self.machine = DynamicCircuit::new(self.context.clone());
        self.advance_state_epoch();
    }

    /// Apply Open-state bookkeeping (timestamp + callback)
    fn mark_open(&mut self) {
        self.advance_state_epoch();
        let Some(data) = self.machine.open_data_mut() else {
            unreachable!("Open state always carries OpenData");
        };
        data.opened_at = self.context.storage.monotonic_time();
        self.callbacks.trigger_open(&self.context.name);
    }

    fn advance_state_epoch(&mut self) {
        self.state_epoch = self.state_epoch.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests;
