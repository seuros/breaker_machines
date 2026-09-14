//! Async-friendly circuit breaker wrapper.
//!
//! This module keeps the core state machine synchronous and runs only short
//! state checks under a mutex. User futures are awaited outside the lock.

use crate::{
    CircuitBreaker, CircuitBuilder, Config, FallbackContext,
    circuit::{CallGate, CallPermit},
    errors::CircuitError,
};
use std::{
    future::Future,
    pin::Pin,
    sync::{Mutex, MutexGuard},
};

pub(crate) type BoxFutureResult<T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send>>;
pub(crate) type AsyncFallbackFn<T, E> =
    Box<dyn FnOnce(FallbackContext) -> BoxFutureResult<T, E> + Send>;

/// Options for async circuit breaker calls.
pub struct AsyncCallOptions<T, E> {
    pub(crate) fallback: Option<AsyncFallbackFn<T, E>>,
}

impl<T, E> Default for AsyncCallOptions<T, E> {
    fn default() -> Self {
        Self { fallback: None }
    }
}

impl<T, E> AsyncCallOptions<T, E> {
    /// Create new async call options with no fallback.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set an async fallback function called when the circuit is open.
    pub fn with_fallback<F, Fut>(mut self, fallback: F) -> Self
    where
        F: FnOnce(FallbackContext) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, E>> + Send + 'static,
    {
        self.fallback = Some(Box::new(move |ctx| Box::pin(fallback(ctx))));
        self
    }
}

enum AsyncCallGate<'a> {
    Execute {
        permit: CallPermit,
        start: f64,
        probe: HalfOpenProbe<'a>,
        state_epoch: u64,
    },
    Open {
        permit: CallPermit,
        context: FallbackContext,
    },
}

struct HalfOpenProbe<'a> {
    circuit: &'a AsyncCircuitBreaker,
    active: bool,
    state_epoch: u64,
}

impl<'a> HalfOpenProbe<'a> {
    fn new(circuit: &'a AsyncCircuitBreaker, active: bool, state_epoch: u64) -> Self {
        Self {
            circuit,
            active,
            state_epoch,
        }
    }

    fn disarm(&mut self) {
        self.active = false;
    }
}

impl Drop for HalfOpenProbe<'_> {
    fn drop(&mut self) {
        if self.active {
            self.circuit
                .lock_inner()
                .release_half_open_probe(self.state_epoch);
        }
    }
}

/// Async-friendly circuit breaker.
///
/// `AsyncCircuitBreaker` can be shared across tasks with `Arc`. It does not
/// hold its internal mutex while awaiting the protected operation.
pub struct AsyncCircuitBreaker {
    inner: Mutex<CircuitBreaker>,
}

impl AsyncCircuitBreaker {
    /// Create a new async circuit breaker.
    pub fn new(name: String, config: Config) -> Self {
        Self::from_circuit(CircuitBreaker::new(name, config))
    }

    /// Create a builder for async circuit breakers.
    pub fn builder(name: impl Into<String>) -> CircuitBuilder {
        CircuitBreaker::builder(name)
    }

    /// Wrap an existing synchronous circuit breaker.
    pub fn from_circuit(circuit: CircuitBreaker) -> Self {
        Self {
            inner: Mutex::new(circuit),
        }
    }

    /// Return the wrapped synchronous circuit breaker.
    pub fn into_inner(self) -> CircuitBreaker {
        self.inner
            .into_inner()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Execute an async fallible operation with circuit breaker protection.
    pub async fn call<F, Fut, T, E: 'static>(&self, operation: F) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        self.call_with_options(operation, AsyncCallOptions::default())
            .await
    }

    /// Execute an async fallible operation with async call options.
    pub async fn call_with_options<F, Fut, T, E: 'static>(
        &self,
        operation: F,
        options: AsyncCallOptions<T, E>,
    ) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        let gate = {
            let mut circuit = self.lock_inner();
            match circuit.prepare_call()? {
                CallGate::Execute(permit) => AsyncCallGate::Execute {
                    start: circuit.start_time(),
                    probe: HalfOpenProbe::new(self, permit.half_open_probe(), permit.state_epoch()),
                    state_epoch: permit.state_epoch(),
                    permit,
                },
                CallGate::Open {
                    _permit: permit,
                    context,
                } => AsyncCallGate::Open { permit, context },
            }
        };

        match gate {
            AsyncCallGate::Execute {
                permit,
                start,
                mut probe,
                state_epoch,
            } => {
                let half_open_probe = permit.half_open_probe();
                let result = operation().await;
                let output = {
                    let mut circuit = self.lock_inner();
                    // `complete_call` releases the probe before invoking storage,
                    // classifiers, or callbacks. Disarming here prevents a panic
                    // in any of those hooks from releasing another task's slot.
                    probe.disarm();
                    circuit.complete_call(start, result, half_open_probe, state_epoch)
                };
                drop(permit);
                output
            }
            AsyncCallGate::Open { permit, context } => {
                drop(permit);

                if let Some(fallback) = options.fallback {
                    return fallback(context).await.map_err(CircuitError::Execution);
                }

                Err(CircuitError::Open {
                    circuit: context.circuit_name,
                    opened_at: context.opened_at,
                })
            }
        }
    }

    /// Record a successful operation and drive HalfOpen -> Closed transitions.
    pub fn record_success_and_maybe_close(&self, duration: f64) {
        self.lock_inner().record_success_and_maybe_close(duration);
    }

    /// Record a failed operation and attempt to trip the circuit.
    pub fn record_failure_and_maybe_trip(&self, duration: f64) {
        self.lock_inner().record_failure_and_maybe_trip(duration);
    }

    /// Record a successful operation.
    pub fn record_success(&self, duration: f64) {
        self.lock_inner().record_success(duration);
    }

    /// Record a failed operation.
    pub fn record_failure(&self, duration: f64) {
        self.lock_inner().record_failure(duration);
    }

    /// Check failure threshold and attempt to trip the circuit.
    pub fn check_and_trip(&self) -> bool {
        self.lock_inner().check_and_trip()
    }

    /// Check if circuit is open.
    pub fn is_open(&self) -> bool {
        self.lock_inner().is_open()
    }

    /// Check if circuit is closed.
    pub fn is_closed(&self) -> bool {
        self.lock_inner().is_closed()
    }

    /// Get current state name.
    pub fn state_name(&self) -> &'static str {
        self.lock_inner().state_name()
    }

    /// Clear all events and reset circuit to Closed state.
    pub fn reset(&self) {
        self.lock_inner().reset();
    }

    fn lock_inner(&self) -> MutexGuard<'_, CircuitBreaker> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests;
