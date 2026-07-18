//! Async circuit breaker backed by an authoritative distributed state store.
//!
//! Unlike [`AsyncCircuitBreaker`](crate::AsyncCircuitBreaker), this type keeps
//! no local FSM. Every gateway observes the same state generation, open
//! timestamp, cooldown, and fenced half-open probe lease.

use crate::{
    AsyncCallOptions, AsyncStorageBackend, BulkheadGuard, BulkheadSemaphore, CircuitError,
    CircuitSnapshot, Config, FailureClassifier, FailureContext, FailurePolicy, FallbackContext,
    ProbeDecision, ProbeLease, ProbePolicy, SharedCircuitState, StateTransition, StorageError,
    StorageUpdate, StoredOutcome, callbacks::Callbacks,
};
use alloc::string::String;
use alloc::sync::Arc;
use core::fmt;
use core::future::Future;
use std::time::Instant;

enum DistributedCallGate {
    Execute {
        _permit: Option<BulkheadGuard>,
        generation: u64,
        probe: Option<ProbeLease>,
    },
    Open {
        _permit: Option<BulkheadGuard>,
        context: FallbackContext,
    },
}

/// Runtime-agnostic async circuit breaker with storage-owned distributed state.
///
/// The backend performs threshold transitions and probe elections atomically.
/// Protected operations and fallbacks are awaited without holding a mutex or
/// storage connection. A cancelled probe remains fenced until its short lease
/// expires, allowing another node to recover even if the elected node crashes.
pub struct DistributedCircuitBreaker {
    name: String,
    config: Config,
    storage: Arc<dyn AsyncStorageBackend>,
    failure_classifier: Option<Arc<dyn FailureClassifier>>,
    bulkhead: Option<Arc<BulkheadSemaphore>>,
    callbacks: Callbacks,
}

impl DistributedCircuitBreaker {
    pub(crate) fn from_parts(
        name: String,
        config: Config,
        storage: Arc<dyn AsyncStorageBackend>,
        failure_classifier: Option<Arc<dyn FailureClassifier>>,
        bulkhead: Option<Arc<BulkheadSemaphore>>,
        callbacks: Callbacks,
    ) -> Self {
        Self {
            name,
            config,
            storage,
            failure_classifier,
            bulkhead,
            callbacks,
        }
    }

    /// Execute an async operation using the shared FSM.
    pub async fn call<F, Fut, T, E: 'static>(&self, operation: F) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        self.call_with_options(operation, AsyncCallOptions::default())
            .await
    }

    /// Execute an async operation with an optional async open-state fallback.
    pub async fn call_with_options<F, Fut, T, E: 'static>(
        &self,
        operation: F,
        options: AsyncCallOptions<T, E>,
    ) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        match self.prepare_call().await? {
            DistributedCallGate::Execute {
                _permit: permit,
                generation,
                probe,
            } => {
                let start = Instant::now();
                let result = operation().await;
                let duration = start.elapsed().as_secs_f64();
                drop(permit);

                let outcome = match &result {
                    Ok(_) => StoredOutcome::Success,
                    Err(error) if self.should_record_failure(error, duration) => {
                        StoredOutcome::Failure
                    }
                    Err(_) => StoredOutcome::Ignored,
                };

                let update = if let Some(lease) = probe {
                    self.storage
                        .complete_probe(&self.name, lease, outcome, duration, self.probe_policy())
                        .await
                        .map_err(CircuitError::Storage)?
                } else if outcome == StoredOutcome::Ignored {
                    StorageUpdate {
                        snapshot: self
                            .storage
                            .load_state(&self.name)
                            .await
                            .map_err(CircuitError::Storage)?,
                        transition: None,
                        applied: false,
                    }
                } else {
                    self.storage
                        .record_outcome(
                            &self.name,
                            generation,
                            outcome,
                            duration,
                            self.failure_policy(),
                        )
                        .await
                        .map_err(CircuitError::Storage)?
                };

                self.trigger_transition(update);
                result.map_err(CircuitError::Execution)
            }
            DistributedCallGate::Open {
                _permit: permit,
                context,
            } => {
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

    /// Load the authoritative shared state.
    pub async fn state(&self) -> Result<CircuitSnapshot, StorageError> {
        self.storage.load_state(&self.name).await
    }

    /// Check whether the authoritative state is open.
    pub async fn is_open(&self) -> Result<bool, StorageError> {
        self.state()
            .await
            .map(|snapshot| snapshot.state == SharedCircuitState::Open)
    }

    /// Check whether the authoritative state is closed.
    pub async fn is_closed(&self) -> Result<bool, StorageError> {
        self.state()
            .await
            .map(|snapshot| snapshot.state == SharedCircuitState::Closed)
    }

    /// Reset shared metrics and FSM state while advancing its generation.
    pub async fn reset(&self) -> Result<CircuitSnapshot, StorageError> {
        self.storage.reset(&self.name).await
    }

    async fn prepare_call<E>(&self) -> Result<DistributedCallGate, CircuitError<E>> {
        let permit = if let Some(bulkhead) = &self.bulkhead {
            Some(
                bulkhead
                    .try_acquire()
                    .ok_or_else(|| CircuitError::BulkheadFull {
                        circuit: self.name.clone(),
                        limit: bulkhead.limit(),
                    })?,
            )
        } else {
            None
        };

        let snapshot = self
            .storage
            .load_state(&self.name)
            .await
            .map_err(CircuitError::Storage)?;

        if snapshot.state == SharedCircuitState::Closed {
            return Ok(DistributedCallGate::Execute {
                _permit: permit,
                generation: snapshot.generation,
                probe: None,
            });
        }

        match self
            .storage
            .try_begin_probe(&self.name, self.config.probe_timeout_secs)
            .await
            .map_err(CircuitError::Storage)?
        {
            ProbeDecision::Closed(snapshot) => Ok(DistributedCallGate::Execute {
                _permit: permit,
                generation: snapshot.generation,
                probe: None,
            }),
            ProbeDecision::Open(snapshot) => Ok(DistributedCallGate::Open {
                _permit: permit,
                context: self.fallback_context(snapshot),
            }),
            ProbeDecision::Busy(_) => Err(CircuitError::HalfOpenLimitReached {
                circuit: self.name.clone(),
            }),
            ProbeDecision::Acquired {
                lease,
                transitioned,
                ..
            } => {
                if transitioned {
                    self.callbacks.trigger_half_open(&self.name);
                }
                Ok(DistributedCallGate::Execute {
                    _permit: permit,
                    generation: lease.generation,
                    probe: Some(lease),
                })
            }
        }
    }

    fn fallback_context(&self, snapshot: CircuitSnapshot) -> FallbackContext {
        FallbackContext {
            circuit_name: self.name.clone(),
            opened_at: snapshot.opened_at.unwrap_or(0.0),
            state: snapshot.state.name(),
        }
    }

    fn failure_policy(&self) -> FailurePolicy {
        FailurePolicy {
            failure_threshold: self.config.failure_threshold,
            failure_rate_threshold: self.config.failure_rate_threshold,
            minimum_calls: self.config.minimum_calls,
            failure_window_secs: self.config.failure_window_secs,
            open_timeout_secs: self.config.half_open_delay_secs(),
        }
    }

    fn probe_policy(&self) -> ProbePolicy {
        ProbePolicy {
            success_threshold: self.config.success_threshold,
            open_timeout_secs: self.config.half_open_delay_secs(),
        }
    }

    fn should_record_failure<E: 'static>(&self, error: &E, duration: f64) -> bool {
        self.failure_classifier.as_ref().is_none_or(|classifier| {
            classifier.should_trip(&FailureContext {
                circuit_name: &self.name,
                error,
                duration,
            })
        })
    }

    fn trigger_transition(&self, update: StorageUpdate) {
        match update.transition {
            Some(StateTransition::Opened) => self.callbacks.trigger_open(&self.name),
            Some(StateTransition::Closed) => self.callbacks.trigger_close(&self.name),
            None => {}
        }
    }
}

impl fmt::Debug for DistributedCircuitBreaker {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DistributedCircuitBreaker")
            .field("name", &self.name)
            .field("config", &self.config)
            .field("storage", &"<dyn AsyncStorageBackend>")
            .field("failure_classifier", &self.failure_classifier.is_some())
            .field("bulkhead", &self.bulkhead)
            .field("callbacks", &self.callbacks)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Clock, MemoryStorage};
    use core::future::{Future, pending};
    use core::pin::Pin;
    use core::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;
    use std::task::{Context, Poll, Waker};

    #[derive(Debug, Clone)]
    struct ManualClock {
        millis: Arc<AtomicU64>,
    }

    impl ManualClock {
        fn new(seconds: u64) -> Self {
            Self {
                millis: Arc::new(AtomicU64::new(seconds * 1000)),
            }
        }

        fn advance(&self, seconds: u64) {
            self.millis.fetch_add(seconds * 1000, Ordering::SeqCst);
        }
    }

    impl Clock for ManualClock {
        fn now_secs(&self) -> f64 {
            self.millis.load(Ordering::SeqCst) as f64 / 1000.0
        }
    }

    fn poll_once<F: Future>(future: Pin<&mut F>) -> Poll<F::Output> {
        let waker = Waker::noop();
        let mut context = Context::from_waker(waker);
        Future::poll(future, &mut context)
    }

    fn test_breaker(store: Arc<MemoryStorage>, name: &str) -> DistributedCircuitBreaker {
        crate::CircuitBreaker::builder(name)
            .failure_threshold(1)
            .half_open_timeout_secs(10.0)
            .probe_timeout_secs(2.0)
            .success_threshold(1)
            .build_distributed(store)
    }

    #[test]
    fn gateways_share_state_and_opened_at() {
        pollster::block_on(async {
            let clock = ManualClock::new(100);
            let store = Arc::new(MemoryStorage::with_clock(Box::new(clock)));
            let gateway_a = test_breaker(store.clone(), "payments");
            let gateway_b = test_breaker(store, "payments");

            let result = gateway_a
                .call(|| async { Err::<(), _>("service unavailable") })
                .await;
            assert!(matches!(result, Err(CircuitError::Execution(_))));

            let snapshot = gateway_b.state().await.unwrap();
            assert_eq!(snapshot.state, SharedCircuitState::Open);
            assert_eq!(snapshot.opened_at, Some(100.0));
            assert_eq!(snapshot.retry_at, Some(110.0));

            let rejected = gateway_b.call(|| async { Ok::<_, &str>(()) }).await;
            assert!(matches!(
                rejected,
                Err(CircuitError::Open {
                    opened_at: 100.0,
                    ..
                })
            ));
        });
    }

    #[test]
    fn gateways_share_the_failure_rate_window() {
        pollster::block_on(async {
            let store = Arc::new(MemoryStorage::new());
            let gateway_a = crate::CircuitBreaker::builder("search")
                .disable_failure_threshold()
                .failure_rate(0.5)
                .minimum_calls(4)
                .build_distributed(store.clone());
            let gateway_b = crate::CircuitBreaker::builder("search")
                .disable_failure_threshold()
                .failure_rate(0.5)
                .minimum_calls(4)
                .build_distributed(store);

            gateway_a
                .call(|| async { Ok::<_, &str>(()) })
                .await
                .unwrap();
            let _ = gateway_b
                .call(|| async { Err::<(), _>("first failure") })
                .await;
            gateway_a
                .call(|| async { Ok::<_, &str>(()) })
                .await
                .unwrap();
            let _ = gateway_b
                .call(|| async { Err::<(), _>("second failure") })
                .await;

            assert!(gateway_a.is_open().await.unwrap());
            assert_eq!(gateway_a.state().await.unwrap().generation, 1);
        });
    }

    #[test]
    fn only_one_gateway_owns_probe_and_expired_lease_recovers() {
        pollster::block_on(async {
            let clock = ManualClock::new(100);
            let store = Arc::new(MemoryStorage::with_clock(Box::new(clock.clone())));
            let gateway_a = test_breaker(store.clone(), "payments");
            let gateway_b = test_breaker(store, "payments");

            let _ = gateway_a
                .call(|| async { Err::<(), _>("service unavailable") })
                .await;
            clock.advance(10);

            let mut first_probe = Box::pin(gateway_a.call(pending::<Result<(), &str>>));
            assert!(poll_once(first_probe.as_mut()).is_pending());

            let competing = gateway_b.call(|| async { Ok::<_, &str>(()) }).await;
            assert!(matches!(
                competing,
                Err(CircuitError::HalfOpenLimitReached { .. })
            ));

            drop(first_probe);
            clock.advance(2);

            gateway_b
                .call(|| async { Ok::<_, &str>(()) })
                .await
                .unwrap();
            assert!(gateway_a.is_closed().await.unwrap());
        });
    }

    #[test]
    fn stale_probe_token_cannot_transition_new_generation() {
        pollster::block_on(async {
            let clock = ManualClock::new(10);
            let store = MemoryStorage::with_clock(Box::new(clock.clone()));
            let policy = FailurePolicy {
                failure_threshold: Some(1),
                failure_rate_threshold: None,
                minimum_calls: 1,
                failure_window_secs: 60.0,
                open_timeout_secs: 1.0,
            };

            store
                .record_outcome("api", 0, StoredOutcome::Failure, 0.1, policy)
                .await
                .unwrap();
            clock.advance(1);

            let first = match store.try_begin_probe("api", 1.0).await.unwrap() {
                ProbeDecision::Acquired { lease, .. } => lease,
                decision => panic!("expected first probe, got {decision:?}"),
            };
            clock.advance(1);
            let second = match store.try_begin_probe("api", 1.0).await.unwrap() {
                ProbeDecision::Acquired { lease, .. } => lease,
                decision => panic!("expected replacement probe, got {decision:?}"),
            };

            let stale = store
                .complete_probe(
                    "api",
                    first,
                    StoredOutcome::Failure,
                    0.1,
                    ProbePolicy {
                        success_threshold: 1,
                        open_timeout_secs: 1.0,
                    },
                )
                .await
                .unwrap();
            assert!(!stale.applied);
            assert_eq!(stale.snapshot.state, SharedCircuitState::HalfOpen);
            assert_eq!(crate::StorageBackend::event_log(&store, "api", 10).len(), 1);

            let current = store
                .complete_probe(
                    "api",
                    second,
                    StoredOutcome::Success,
                    0.1,
                    ProbePolicy {
                        success_threshold: 1,
                        open_timeout_secs: 1.0,
                    },
                )
                .await
                .unwrap();
            assert!(current.applied);
            assert_eq!(current.transition, Some(StateTransition::Closed));
            assert_eq!(current.snapshot.state, SharedCircuitState::Closed);
        });
    }

    #[test]
    fn reset_fences_normal_calls_from_the_previous_generation() {
        pollster::block_on(async {
            let store = MemoryStorage::new();
            let admitted = store.load_state("api").await.unwrap();
            let reset = AsyncStorageBackend::reset(&store, "api").await.unwrap();

            assert_eq!(reset.generation, admitted.generation + 1);

            let stale = store
                .record_outcome(
                    "api",
                    admitted.generation,
                    StoredOutcome::Failure,
                    0.1,
                    FailurePolicy {
                        failure_threshold: Some(1),
                        failure_rate_threshold: None,
                        minimum_calls: 1,
                        failure_window_secs: 60.0,
                        open_timeout_secs: 10.0,
                    },
                )
                .await
                .unwrap();

            assert!(!stale.applied);
            assert_eq!(stale.snapshot.state, SharedCircuitState::Closed);
            assert!(crate::StorageBackend::event_log(&store, "api", 10).is_empty());
        });
    }

    #[test]
    fn distributed_call_future_is_send_when_operation_is_send() {
        fn assert_send<T: Send>(_: T) {}

        let store = Arc::new(MemoryStorage::new());
        let gateway = test_breaker(store, "payments");
        assert_send(gateway.call(|| async { Ok::<_, String>(()) }));
    }
}
