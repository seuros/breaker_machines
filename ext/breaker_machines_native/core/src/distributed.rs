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
mod tests;
