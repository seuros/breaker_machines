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

type BoxFutureResult<T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send>>;
type AsyncFallbackFn<T, E> = Box<dyn FnOnce(FallbackContext) -> BoxFutureResult<T, E> + Send>;

/// Options for async circuit breaker calls.
pub struct AsyncCallOptions<T, E> {
    fallback: Option<AsyncFallbackFn<T, E>>,
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
    },
    Open {
        permit: CallPermit,
        context: FallbackContext,
    },
}

struct HalfOpenProbe<'a> {
    circuit: &'a AsyncCircuitBreaker,
    active: bool,
}

impl<'a> HalfOpenProbe<'a> {
    fn new(circuit: &'a AsyncCircuitBreaker, active: bool) -> Self {
        Self { circuit, active }
    }

    fn disarm(&mut self) {
        self.active = false;
    }
}

impl Drop for HalfOpenProbe<'_> {
    fn drop(&mut self) {
        if self.active {
            self.circuit.lock_inner().release_half_open_probe();
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
                    probe: HalfOpenProbe::new(self, permit.half_open_probe()),
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
            } => {
                let half_open_probe = permit.half_open_probe();
                let result = operation().await;
                let output = {
                    let mut circuit = self.lock_inner();
                    circuit.complete_call(start, result, half_open_probe)
                };
                probe.disarm();
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
mod tests {
    use super::*;

    fn poll_once<F: Future>(future: Pin<&mut F>) -> std::task::Poll<F::Output> {
        let waker = std::task::Waker::noop();
        let mut context = std::task::Context::from_waker(waker);
        std::future::Future::poll(future, &mut context)
    }

    #[test]
    fn async_call_records_success() {
        pollster::block_on(async {
            let circuit = AsyncCircuitBreaker::builder("test").build_async();

            let result = circuit.call(|| async { Ok::<_, String>("success") }).await;

            assert_eq!(result.unwrap(), "success");
            assert!(circuit.is_closed());
        });
    }

    #[test]
    fn async_call_opens_after_threshold() {
        pollster::block_on(async {
            let circuit = AsyncCircuitBreaker::builder("test")
                .failure_threshold(2)
                .build_async();

            let _ = circuit.call(|| async { Err::<(), _>("error 1") }).await;
            assert!(circuit.is_closed());

            let _ = circuit.call(|| async { Err::<(), _>("error 2") }).await;
            assert!(circuit.is_open());

            let result = circuit.call(|| async { Ok::<_, &str>("blocked") }).await;
            assert!(matches!(result, Err(CircuitError::Open { .. })));
        });
    }

    #[test]
    fn async_fallback_runs_when_open() {
        pollster::block_on(async {
            let circuit = AsyncCircuitBreaker::builder("test")
                .failure_threshold(1)
                .build_async();

            let _ = circuit.call(|| async { Err::<(), _>("error") }).await;
            assert!(circuit.is_open());

            let result = circuit
                .call_with_options(
                    || async { Ok::<String, String>("should not execute".to_string()) },
                    AsyncCallOptions::new().with_fallback(|ctx| async move {
                        assert_eq!(ctx.circuit_name, "test");
                        assert_eq!(ctx.state, "Open");
                        Ok("fallback response".to_string())
                    }),
                )
                .await;

            assert_eq!(result.unwrap(), "fallback response");
        });
    }

    #[test]
    fn async_call_with_fallback_future_is_send() {
        fn assert_send<T: Send>(_: T) {}

        let circuit = std::sync::Arc::new(
            AsyncCircuitBreaker::builder("test")
                .failure_threshold(1)
                .build_async(),
        );
        let future = async move {
            circuit
                .call_with_options(
                    || async { Ok::<String, String>("success".to_string()) },
                    AsyncCallOptions::new()
                        .with_fallback(|_ctx| async { Ok("fallback".to_string()) }),
                )
                .await
        };

        assert_send(future);
    }

    #[test]
    fn async_half_open_limits_in_flight_probes() {
        let circuit = AsyncCircuitBreaker::builder("test")
            .failure_threshold(1)
            .half_open_timeout_secs(0.0)
            .success_threshold(1)
            .build_async();

        let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
        assert!(circuit.is_open());

        let mut first =
            Box::pin(circuit.call(std::future::pending::<Result<&'static str, &'static str>>));
        assert!(matches!(
            poll_once(first.as_mut()),
            std::task::Poll::Pending
        ));

        let second = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("second") }));
        assert!(matches!(
            second,
            Err(CircuitError::HalfOpenLimitReached { .. })
        ));

        drop(first);

        let third = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("third") }));
        assert_eq!(third.unwrap(), "third");
        assert!(circuit.is_closed());
    }

    #[test]
    fn async_open_fallback_does_not_hold_bulkhead_permit() {
        let circuit = AsyncCircuitBreaker::builder("test")
            .failure_threshold(1)
            .max_concurrency(1)
            .build_async();

        let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
        assert!(circuit.is_open());

        let mut fallback =
            Box::pin(circuit.call_with_options(
                || async { Ok::<_, &'static str>("should not execute") },
                AsyncCallOptions::new().with_fallback(|_ctx| {
                    std::future::pending::<Result<&'static str, &'static str>>()
                }),
            ));
        assert!(matches!(
            poll_once(fallback.as_mut()),
            std::task::Poll::Pending
        ));

        let result = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("blocked") }));
        assert!(matches!(result, Err(CircuitError::Open { .. })));

        drop(fallback);
    }
}
