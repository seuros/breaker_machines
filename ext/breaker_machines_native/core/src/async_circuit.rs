//! Async-friendly circuit breaker wrapper.
//!
//! This module keeps the core state machine synchronous and runs only short
//! state checks under a mutex. User futures are awaited outside the lock.

use crate::{
    CircuitBreaker, CircuitBuilder, Config, FallbackContext,
    circuit::{CallGate, CallPermit, CallTicket, CircuitState},
    errors::CircuitError,
};
use core::convert::Infallible;
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex, MutexGuard},
};

pub(crate) type BoxFutureResult<T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send>>;
pub(crate) type AsyncFallbackFn<T, E> =
    Box<dyn FnOnce(FallbackContext) -> BoxFutureResult<T, E> + Send>;

/// Options for async circuit breaker calls.
#[must_use = "call options do nothing unless passed to `call_with_options`"]
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

    /// Resolve an open-circuit gate: run the fallback if present, otherwise
    /// return the rejection error.
    pub(crate) async fn resolve_open(self, context: FallbackContext) -> Result<T, CircuitError<E>> {
        match self.fallback {
            Some(fallback) => fallback(context).await.map_err(CircuitError::Execution),
            None => Err(context.into_open_error()),
        }
    }
}

enum AsyncCallGate {
    Execute(CallTicket),
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
    const fn new(circuit: &'a AsyncCircuitBreaker, active: bool, state_epoch: u64) -> Self {
        Self {
            circuit,
            active,
            state_epoch,
        }
    }

    const fn disarm(&mut self) {
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

/// Admission for one operation that runs across `.await`, from
/// [`AsyncCircuitBreaker::try_acquire`].
///
/// Hand it to [`complete`](Self::complete) once the outcome is known, or
/// [`abandon`](Self::abandon) when nothing should be recorded. Unlike the sync
/// [`CallTicket`], dropping it (a cancelled future, an early return) gives the
/// half-open probe slot and bulkhead permit back, as [`AsyncCircuitBreaker::call`]
/// does for the future it runs.
#[must_use = "pass the ticket to `complete` or `abandon`; dropping it records no outcome"]
pub struct AsyncCallTicket<'a> {
    circuit: &'a AsyncCircuitBreaker,
    ticket: Option<CallTicket>,
}

impl core::fmt::Debug for AsyncCallTicket<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("AsyncCallTicket")
            .field("ticket", &self.ticket)
            .finish_non_exhaustive()
    }
}

impl AsyncCallTicket<'_> {
    /// Record the outcome of the admitted operation, exactly as
    /// [`AsyncCircuitBreaker::call`] would: the failure classifier applies, and
    /// an outcome admitted before the circuit last changed state still counts
    /// in the metrics but cannot drive a transition.
    ///
    /// # Errors
    ///
    /// Returns the operation's own error as [`CircuitError::Execution`].
    pub fn complete<T, E: 'static>(mut self, result: Result<T, E>) -> Result<T, CircuitError<E>> {
        let ticket = self.take();
        self.circuit.lock_inner().complete(ticket, result)
    }

    /// Give back the admission without recording an outcome; see
    /// [`CircuitBreaker::abandon`].
    pub fn abandon(mut self) {
        let ticket = self.take();
        self.circuit.lock_inner().abandon(ticket);
    }

    fn take(&mut self) -> CallTicket {
        self.ticket
            .take()
            .unwrap_or_else(|| unreachable!("a ticket is consumed once, by complete or abandon"))
    }
}

impl Drop for AsyncCallTicket<'_> {
    fn drop(&mut self) {
        if let Some(ticket) = self.ticket.take() {
            self.circuit.lock_inner().abandon(ticket);
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
    ///
    /// `name` accepts `&str`, `String`, or an existing `Arc<str>`; the latter
    /// is shared without copying the bytes.
    #[must_use]
    pub fn new(name: impl Into<Arc<str>>, config: Config) -> Self {
        Self::from_circuit(CircuitBreaker::new(name, config))
    }

    /// Create a builder for async circuit breakers.
    pub fn builder(name: impl Into<String>) -> CircuitBuilder {
        CircuitBreaker::builder(name)
    }

    /// Wrap an existing synchronous circuit breaker.
    #[must_use]
    pub const fn from_circuit(circuit: CircuitBreaker) -> Self {
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
    ///
    /// # Errors
    ///
    /// Same as [`call_with_options`](Self::call_with_options) without a
    /// fallback.
    pub async fn call<F, Fut, T, E: 'static>(&self, operation: F) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        self.call_with_options(operation, AsyncCallOptions::default())
            .await
    }

    /// Execute an async fallible operation with async call options.
    ///
    /// # Errors
    ///
    /// - [`CircuitError::BulkheadFull`] when the concurrency limit is reached.
    /// - [`CircuitError::HalfOpenLimitReached`] when every half-open probe slot
    ///   is taken.
    /// - [`CircuitError::Open`] when the circuit is open and no fallback is set.
    /// - [`CircuitError::Execution`] wrapping the operation's (or fallback's)
    ///   own error.
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
                CallGate::Execute(permit) => AsyncCallGate::Execute(circuit.ticket(permit)),
                CallGate::Open {
                    _permit: permit,
                    context,
                } => AsyncCallGate::Open { permit, context },
            }
        };

        match gate {
            AsyncCallGate::Execute(ticket) => {
                // Releases the reserved probe slot if this future is dropped
                // while the operation is pending.
                let mut probe =
                    HalfOpenProbe::new(self, ticket.half_open_probe(), ticket.state_epoch());
                let result = operation().await;
                let mut circuit = self.lock_inner();
                // `complete` releases the probe before invoking storage,
                // classifiers, or callbacks. Disarming here prevents a panic
                // in any of those hooks from releasing another task's slot.
                probe.disarm();
                circuit.complete(ticket, result)
            }
            AsyncCallGate::Open { permit, context } => {
                drop(permit);
                options.resolve_open(context).await
            }
        }
    }

    /// Admit one operation without running it, for work whose outcome is
    /// only known after an `.await` this circuit cannot wrap; see
    /// [`CircuitBreaker::try_acquire`]. The ticket borrows the circuit and
    /// releases its half-open probe slot if it is dropped before
    /// [`AsyncCallTicket::complete`] or [`AsyncCallTicket::abandon`].
    ///
    /// # Errors
    ///
    /// The same rejections [`call`](Self::call) returns without a fallback:
    /// - [`CircuitError::BulkheadFull`] when the concurrency limit is reached.
    /// - [`CircuitError::Open`] while the cooldown has not elapsed.
    /// - [`CircuitError::HalfOpenLimitReached`] when every probe slot is taken.
    pub fn try_acquire(&self) -> Result<AsyncCallTicket<'_>, CircuitError<Infallible>> {
        let ticket = self.lock_inner().try_acquire()?;
        Ok(AsyncCallTicket {
            circuit: self,
            ticket: Some(ticket),
        })
    }

    /// Record an operation that ran outside this circuit's admission and
    /// return the state it left; see [`CircuitBreaker::observe`].
    pub fn observe<E: 'static>(&self, outcome: Result<(), E>, duration: f64) -> CircuitState {
        self.lock_inner().observe(outcome, duration)
    }

    /// Record a successful operation and drive `HalfOpen` -> Closed transitions.
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

    /// Get the current state.
    pub fn state(&self) -> CircuitState {
        self.lock_inner().state()
    }

    /// Get current state name.
    pub fn state_name(&self) -> &'static str {
        self.lock_inner().state_name()
    }

    /// Storage-clock time this circuit opened, while it is Open; see
    /// [`CircuitBreaker::opened_at`].
    pub fn opened_at(&self) -> Option<f64> {
        self.lock_inner().opened_at()
    }

    /// Seconds until the next admission may run a half-open probe, while the
    /// circuit is Open; see [`CircuitBreaker::retry_after`].
    pub fn retry_after(&self) -> Option<f64> {
        self.lock_inner().retry_after()
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
