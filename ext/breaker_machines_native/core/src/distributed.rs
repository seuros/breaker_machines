//! A circuit whose state lives in a shared store.
//!
//! Unlike [`AsyncCircuitBreaker`](crate::AsyncCircuitBreaker), this circuit
//! keeps no local state machine: every gateway reads the same generation,
//! open instant, cooldown and fenced half-open probe lease from the store.

use crate::callbacks::Transition;
use crate::circuit::Shared;
use crate::clock::Draws;
use crate::{
    AsyncStorageBackend, CircuitError, CircuitSnapshot, FailurePolicy, FallbackContext, Policy,
    ProbeDecision, ProbeLease, ProbePolicy, Refusal, State, StateTransition, StorageError,
    StorageErrorKind, StorageUpdate, StoredOutcome,
};
use core::convert::Infallible;
use core::future::Future;
use core::sync::atomic::{AtomicU32, Ordering};
use core::time::Duration;
use std::sync::{Arc, Mutex, PoisonError};

/// A runtime-agnostic async circuit whose state the store owns.
///
/// The store performs threshold transitions and probe elections
/// atomically. Operations and fallbacks are awaited holding no lock and no
/// storage connection. A cancelled probe stays fenced until its lease
/// expires, so another node recovers even if the elected one crashed.
#[derive(Debug)]
pub struct DistributedCircuitBreaker {
    shared: Shared,
    policy: Policy,
    storage: Arc<dyn AsyncStorageBackend>,
    probe_lease: Duration,
    /// Calls this node has in flight, bounded by the policy's
    /// `max_concurrent`.
    in_flight: AtomicU32,
    draws: Mutex<Draws>,
}

/// Frees this node's concurrency slot when the call ends, however it ends.
struct Slot<'a>(&'a AtomicU32);

impl Drop for Slot<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

enum Gate<'a> {
    Execute {
        slot: Option<Slot<'a>>,
        generation: u64,
        probe: Option<ProbeLease>,
    },
    Refused(FallbackContext),
}

impl DistributedCircuitBreaker {
    pub(crate) fn from_parts(
        shared: Shared,
        policy: Policy,
        storage: Arc<dyn AsyncStorageBackend>,
        probe_lease: Duration,
    ) -> Self {
        Self {
            shared,
            policy,
            storage,
            probe_lease,
            in_flight: AtomicU32::new(0),
            draws: Mutex::new(Draws::new()),
        }
    }

    /// The circuit's name, its key in the store.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.shared.name
    }

    /// Await `operation` under the shared state machine.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] when the circuit refuses the call (open,
    /// another node holds the probe lease, this node is at its concurrency
    /// limit, or the store has no fencing identity left:
    /// [`Refusal::Exhausted`]), [`CircuitError::Storage`] when the store
    /// fails, [`CircuitError::Execution`] with the operation's own error.
    pub async fn call<F, Fut, T, E: 'static>(&self, operation: F) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        self.call_with_fallback(operation, |context| async move {
            Err(CircuitError::Refused {
                circuit: context.circuit,
                refusal: context.refusal,
            })
        })
        .await
    }

    /// Await `operation` under the shared state machine, `fallback` if the
    /// circuit refuses it.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Storage`] when the store fails,
    /// [`CircuitError::Refused`] with [`Refusal::Exhausted`] when the store
    /// cannot record the outcome because no generation is left (the
    /// operation's result is dropped, as [`CircuitBreaker`] does),
    /// [`CircuitError::Execution`] with the operation's own error; whatever
    /// `fallback` answers when the call is refused, including when electing
    /// a probe finds no generation or probe token left.
    ///
    /// [`CircuitBreaker`]: crate::CircuitBreaker
    pub async fn call_with_fallback<F, Fut, G, FutG, T, E: 'static>(
        &self,
        operation: F,
        fallback: G,
    ) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
        G: FnOnce(FallbackContext) -> FutG,
        FutG: Future<Output = Result<T, CircuitError<E>>>,
    {
        let (slot, generation, probe) = match self.prepare().await {
            Ok(Gate::Execute {
                slot,
                generation,
                probe,
            }) => (slot, generation, probe),
            Ok(Gate::Refused(context)) => return fallback(context).await,
            // No generation or probe token left to admit with: refused like
            // an exhausted admission, nothing changed.
            Err(error) => match error.kind() {
                StorageErrorKind::Exhausted => {
                    let context = self.shared.fallback_context(Refusal::Exhausted, None);
                    return fallback(context).await;
                }
                StorageErrorKind::Backend => return Err(CircuitError::Storage(error)),
            },
        };
        let start = self.shared.clock.now();
        let result = operation().await;
        let took = self.shared.clock.now().saturating_sub(start);
        drop(slot);

        let outcome = match self.shared.classify(&result, took) {
            Some(crate::Outcome::Success) => StoredOutcome::Success,
            Some(crate::Outcome::Failure) => StoredOutcome::Failure,
            None => StoredOutcome::Ignored,
        };
        let update = match (probe, outcome) {
            (Some(lease), _) => {
                let policy = ProbePolicy {
                    success_threshold: self.policy.recovery().success_threshold(),
                    cooldown: self.cooldown(),
                };
                self.storage
                    .complete_probe(&self.shared.name, lease, outcome, took, policy)
                    .await
                    .map(Some)
            }
            (None, StoredOutcome::Ignored) => Ok(None),
            (None, StoredOutcome::Success | StoredOutcome::Failure) => {
                let policy = FailurePolicy {
                    threshold: self.policy.threshold(),
                    window: self.policy.window(),
                    cooldown: self.cooldown(),
                };
                self.storage
                    .record_outcome(&self.shared.name, generation, outcome, took, policy)
                    .await
                    .map(Some)
            }
        }
        .map_err(|error| self.storage_failed(error))?;
        if let Some(StorageUpdate {
            transition: Some(transition),
            ..
        }) = update
        {
            self.shared.notify([transition_of(transition)]);
        }
        result.map_err(CircuitError::Execution)
    }

    /// The authoritative shared state.
    ///
    /// # Errors
    ///
    /// The store's [`StorageError`].
    pub async fn snapshot(&self) -> Result<CircuitSnapshot, StorageError> {
        self.storage.load_state(&self.shared.name).await
    }

    /// The authoritative shared state's [`State`].
    ///
    /// # Errors
    ///
    /// The store's [`StorageError`].
    pub async fn state(&self) -> Result<State, StorageError> {
        self.snapshot().await.map(|snapshot| snapshot.state)
    }

    /// Clear the shared metrics and state, advancing the generation.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] with [`Refusal::Exhausted`] when no
    /// generation is left; nothing changed. [`CircuitError::Storage`] when
    /// the store fails.
    pub async fn reset(&self) -> Result<CircuitSnapshot, CircuitError<Infallible>> {
        self.storage
            .reset(&self.shared.name)
            .await
            .map_err(|error| self.storage_failed(error))
    }

    /// A store's failure as the circuit answers it: an exhausted fencing
    /// identity is the core's [`Refusal::Exhausted`], anything else a
    /// storage failure.
    fn storage_failed<E>(&self, error: StorageError) -> CircuitError<E> {
        match error.kind() {
            StorageErrorKind::Exhausted => self.shared.refused(Refusal::Exhausted),
            StorageErrorKind::Backend => CircuitError::Storage(error),
        }
    }

    async fn prepare(&self) -> Result<Gate<'_>, StorageError> {
        let slot = match self.take_slot() {
            Ok(slot) => slot,
            Err(refusal) => {
                return Ok(Gate::Refused(self.shared.fallback_context(refusal, None)));
            }
        };
        let snapshot = self.storage.load_state(&self.shared.name).await?;
        // A closed circuit needs no election; route it through the same arm
        // the store answers with.
        let decision = match snapshot.state {
            State::Closed => ProbeDecision::Closed(snapshot),
            State::Open | State::HalfOpen => {
                self.storage
                    .try_begin_probe(&self.shared.name, self.probe_lease)
                    .await?
            }
        };
        Ok(match decision {
            ProbeDecision::Closed(snapshot) => Gate::Execute {
                slot,
                generation: snapshot.generation,
                probe: None,
            },
            // The store's instants are on the store's clock, which this
            // node cannot read: it reports no retry_after.
            ProbeDecision::Open(_) => {
                Gate::Refused(self.shared.fallback_context(Refusal::Open, None))
            }
            ProbeDecision::Busy(_) => {
                Gate::Refused(self.shared.fallback_context(Refusal::Busy, None))
            }
            ProbeDecision::Acquired {
                lease, transition, ..
            } => {
                self.shared.notify(transition.map(transition_of));
                Gate::Execute {
                    slot,
                    generation: lease.generation,
                    probe: Some(lease),
                }
            }
        })
    }

    /// This node's concurrency slot, when the policy bounds it.
    fn take_slot(&self) -> Result<Option<Slot<'_>>, Refusal> {
        let Some(limit) = self.policy.max_concurrent() else {
            return Ok(None);
        };
        // Check and take in one step: the counter never reads past the
        // limit, so it cannot wrap, and a refused call never makes a free
        // slot look taken to a racing one.
        self.in_flight
            .try_update(Ordering::AcqRel, Ordering::Acquire, |taken| {
                taken.checked_add(1).filter(|&next| next <= limit.get())
            })
            .map_err(|_| Refusal::Full)?;
        Ok(Some(Slot(&self.in_flight)))
    }

    fn cooldown(&self) -> Duration {
        let draw = self
            .draws
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .next();
        self.policy.recovery().cooldown().delay(draw)
    }
}

const fn transition_of(transition: StateTransition) -> Transition {
    match transition {
        StateTransition::Opened => Transition::Opened,
        StateTransition::Closed => Transition::Closed,
        StateTransition::HalfOpened => Transition::HalfOpened,
    }
}

#[cfg(test)]
mod tests;
