//! The async storage contract behind [`DistributedCircuitBreaker`], and an
//! in-memory backend for it.
//!
//! [`MemoryStorage`] saturates retry deadlines and half-open probe lease
//! expiries at `Duration::MAX`. Its generations and probe tokens are fencing
//! identities and never wrap: once `u64::MAX` is taken, an operation that
//! needs another answers a [`StorageError`] with nothing changed, and
//! operations that need none are still honoured.
//!
//! [`DistributedCircuitBreaker`]: crate::DistributedCircuitBreaker

use crate::clock::{Clock, SystemClock};
use crate::{Event, Outcome, State, StorageError, Threshold};
use core::future::Future;
use core::num::NonZeroU32;
use core::pin::Pin;
use core::time::Duration;
use std::boxed::Box;
use std::collections::{HashMap, VecDeque};
use std::string::String;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

/// Authoritative state a storage backend reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CircuitSnapshot {
    /// The shared state.
    pub state: State,
    /// Fencing generation; it changes on every transition and reset.
    pub generation: u64,
    /// Storage-clock instant the current open cycle began.
    pub opened_at: Option<Duration>,
    /// Storage-clock instant from which an open circuit may elect a probe.
    pub retry_at: Option<Duration>,
    /// Successful probes in the current half-open generation.
    pub consecutive_successes: u32,
    /// Expiry of the currently elected probe's lease.
    pub probe_expires_at: Option<Duration>,
}

impl Default for CircuitSnapshot {
    /// Closed, generation zero: what a never-seen key reports.
    fn default() -> Self {
        Self {
            state: State::Closed,
            generation: 0,
            opened_at: None,
            retry_at: None,
            consecutive_successes: 0,
            probe_expires_at: None,
        }
    }
}

/// A fenced lease granting one node the right to run a half-open probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeLease {
    /// The half-open generation the lease is valid for.
    pub generation: u64,
    /// The store-issued fencing token.
    pub token: u64,
    /// Storage-clock instant after which another node may take the lease.
    pub expires_at: Duration,
}

/// What [`AsyncStorageBackend::try_begin_probe`] decided.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeDecision {
    /// The circuit closed while admission was in progress.
    Closed(CircuitSnapshot),
    /// The cooldown has not elapsed.
    Open(CircuitSnapshot),
    /// Another node holds the unexpired probe lease.
    Busy(CircuitSnapshot),
    /// This caller won the election.
    Acquired {
        /// The lease the probe completes with.
        lease: ProbeLease,
        /// The state after the lease was taken.
        snapshot: CircuitSnapshot,
        /// Whether this election performed the open to half-open transition.
        transition: Option<StateTransition>,
    },
}

/// The outcome a storage operation records.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoredOutcome {
    /// The operation succeeded.
    Success,
    /// The operation failed and counts toward opening.
    Failure,
    /// The failure classifier ignored the operation.
    Ignored,
}

/// What opening judges: the threshold over the window, and the cooldown to
/// persist against the store's own clock when it opens.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FailurePolicy {
    /// When a closed circuit opens.
    pub threshold: Threshold,
    /// The span of the outcome window.
    pub window: Duration,
    /// The cooldown (already jittered by the caller) if this opens it.
    pub cooldown: Duration,
}

/// What completing a probe judges.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbePolicy {
    /// Successful probes that close the circuit.
    pub success_threshold: NonZeroU32,
    /// The cooldown (already jittered) if a failed probe reopens it.
    pub cooldown: Duration,
}

/// A shared transition a storage operation performed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateTransition {
    /// Closed or half-open to open.
    Opened,
    /// Half-open to closed.
    Closed,
    /// Open to half-open.
    HalfOpened,
}

/// What recording an outcome or completing a probe did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StorageUpdate {
    /// The state after the operation.
    pub snapshot: CircuitSnapshot,
    /// The transition the operation performed, if any.
    pub transition: Option<StateTransition>,
    /// Whether the generation or lease supplied was still current.
    pub applied: Applied,
}

/// Whether a fenced storage operation applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    /// The generation or lease was current; the outcome was recorded.
    Current,
    /// The generation or lease was stale; nothing changed.
    Stale,
}

/// The future every storage operation returns.
pub type StorageFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, StorageError>> + Send + 'a>>;

/// The async, state-level storage contract for distributed circuits.
///
/// Each method must be atomic for one circuit key: `record_outcome` records
/// and opens in one transaction, `try_begin_probe` elects at most one
/// unexpired lease. Every instant comes from the backend's own clock.
pub trait AsyncStorageBackend: Send + Sync + core::fmt::Debug {
    /// The authoritative state; Closed generation zero for an unseen key.
    fn load_state<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot>;

    /// Record a call's outcome and open the circuit if `generation` is
    /// current and the policy's threshold is crossed.
    fn record_outcome<'a>(
        &'a self,
        circuit_name: &'a str,
        generation: u64,
        outcome: StoredOutcome,
        took: Duration,
        policy: FailurePolicy,
    ) -> StorageFuture<'a, StorageUpdate>;

    /// Check the stored cooldown and elect one half-open probe, whose lease
    /// lasts `lease`.
    fn try_begin_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease: Duration,
    ) -> StorageFuture<'a, ProbeDecision>;

    /// Complete a probe only if its generation and token are current; a
    /// stale completion changes nothing.
    fn complete_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease: ProbeLease,
        outcome: StoredOutcome,
        took: Duration,
        policy: ProbePolicy,
    ) -> StorageFuture<'a, StorageUpdate>;

    /// Clear metrics and state, advancing the generation.
    fn reset<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot>;
}

#[derive(Debug, Default)]
struct MemoryCircuit {
    events: VecDeque<Event>,
    snapshot: CircuitSnapshot,
    probe: Option<ProbeLease>,
    next_token: u64,
}

impl MemoryCircuit {
    /// `outcome`s among `events` at or after `since`.
    fn tally<'a>(
        events: impl Iterator<Item = &'a Event>,
        outcome: Outcome,
        since: Duration,
    ) -> u32 {
        let count = events
            .filter(|event| event.outcome == outcome && event.at >= since)
            .count();
        u32::try_from(count).unwrap_or(u32::MAX)
    }

    /// The event `outcome` keeps; an ignored one keeps none.
    const fn event(outcome: StoredOutcome, at: Duration, took: Duration) -> Option<Event> {
        let outcome = match outcome {
            StoredOutcome::Success => Outcome::Success,
            StoredOutcome::Failure => Outcome::Failure,
            StoredOutcome::Ignored => return None,
        };
        Some(Event { at, outcome, took })
    }

    /// Whether `threshold` is exceeded since `since` once `event` is kept:
    /// the oldest outcome goes when `cap` are kept.
    fn crosses(&self, event: &Event, cap: usize, threshold: Threshold, since: Duration) -> bool {
        let evicted = usize::from(self.events.len() >= cap);
        let kept = || {
            self.events
                .iter()
                .skip(evicted)
                .chain(core::iter::once(event))
        };
        threshold.exceeded(
            Self::tally(kept(), Outcome::Failure, since),
            Self::tally(kept(), Outcome::Success, since),
        )
    }

    fn push(&mut self, event: Option<Event>, cap: usize) {
        let Some(event) = event else { return };
        if self.events.len() >= cap {
            self.events.pop_front();
        }
        self.events.push_back(event);
    }

    /// The generation a transition takes. Generations fence in-flight
    /// calls and leases, so one is never reused.
    fn next_generation(&self) -> Result<u64, StorageError> {
        self.snapshot
            .generation
            .checked_add(1)
            .ok_or_else(|| StorageError::new("every circuit generation has been used"))
    }

    /// The token the next lease takes; never reused.
    fn next_token(&self) -> Result<u64, StorageError> {
        self.next_token
            .checked_add(1)
            .ok_or_else(|| StorageError::new("every probe token has been used"))
    }

    const fn transition(&mut self, state: State, generation: u64) {
        self.snapshot.state = state;
        self.snapshot.generation = generation;
        self.snapshot.consecutive_successes = 0;
        self.probe = None;
        self.snapshot.probe_expires_at = None;
    }

    const fn open(&mut self, now: Duration, cooldown: Duration, generation: u64) {
        self.transition(State::Open, generation);
        self.snapshot.opened_at = Some(now);
        self.snapshot.retry_at = Some(now.saturating_add(cooldown));
    }

    fn close(&mut self, generation: u64) {
        self.transition(State::Closed, generation);
        self.snapshot.opened_at = None;
        self.snapshot.retry_at = None;
        self.events.clear();
    }
}

/// An in-memory [`AsyncStorageBackend`] for one process, for tests and
/// single-node deployments. Keeps the newest `cap` outcomes per circuit.
#[derive(Debug)]
pub struct MemoryStorage {
    circuits: Mutex<HashMap<String, MemoryCircuit>>,
    cap: usize,
    clock: Arc<dyn Clock>,
}

impl MemoryStorage {
    /// A store keeping 1000 outcomes per circuit, on the system clock.
    #[must_use]
    pub fn new() -> Self {
        Self::with_clock(SystemClock::new())
    }

    /// A store keeping 1000 outcomes per circuit, on `clock`.
    #[must_use]
    pub fn with_clock(clock: impl Clock + 'static) -> Self {
        Self {
            circuits: Mutex::new(HashMap::new()),
            cap: crate::WINDOW,
            clock: Arc::new(clock),
        }
    }

    fn circuits(&self) -> MutexGuard<'_, HashMap<String, MemoryCircuit>> {
        // Only plain data is mutated under the lock.
        self.circuits.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn with_circuit<T>(
        &self,
        name: &str,
        act: impl FnOnce(&mut MemoryCircuit, Duration) -> T,
    ) -> T {
        let now = self.clock.now();
        act(self.circuits().entry(String::from(name)).or_default(), now)
    }
}

impl Default for MemoryStorage {
    fn default() -> Self {
        Self::new()
    }
}

impl AsyncStorageBackend for MemoryStorage {
    fn load_state<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot> {
        Box::pin(async move {
            Ok(self
                .circuits()
                .get(circuit_name)
                .map(|circuit| circuit.snapshot)
                .unwrap_or_default())
        })
    }

    fn record_outcome<'a>(
        &'a self,
        circuit_name: &'a str,
        generation: u64,
        outcome: StoredOutcome,
        took: Duration,
        policy: FailurePolicy,
    ) -> StorageFuture<'a, StorageUpdate> {
        Box::pin(async move {
            self.with_circuit(circuit_name, |circuit, now| {
                if circuit.snapshot.generation != generation {
                    return Ok(StorageUpdate {
                        snapshot: circuit.snapshot,
                        transition: None,
                        applied: Applied::Stale,
                    });
                }
                let event = MemoryCircuit::event(outcome, now, took);
                let since = now.saturating_sub(policy.window);
                let opens = circuit.snapshot.state == State::Closed
                    && outcome == StoredOutcome::Failure
                    && event.is_some_and(|event| {
                        circuit.crosses(&event, self.cap, policy.threshold, since)
                    });
                let opening = opens.then(|| circuit.next_generation()).transpose()?;
                circuit.push(event, self.cap);
                if let Some(generation) = opening {
                    circuit.open(now, policy.cooldown, generation);
                }
                Ok(StorageUpdate {
                    snapshot: circuit.snapshot,
                    transition: opens.then_some(StateTransition::Opened),
                    applied: Applied::Current,
                })
            })
        })
    }

    fn try_begin_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease: Duration,
    ) -> StorageFuture<'a, ProbeDecision> {
        Box::pin(async move {
            self.with_circuit(circuit_name, |circuit, now| {
                let half_opening = match circuit.snapshot.state {
                    State::Closed => return Ok(ProbeDecision::Closed(circuit.snapshot)),
                    State::Open if circuit.snapshot.retry_at.is_some_and(|at| now < at) => {
                        return Ok(ProbeDecision::Open(circuit.snapshot));
                    }
                    State::Open => Some(circuit.next_generation()?),
                    State::HalfOpen if circuit.probe.is_some_and(|held| held.expires_at > now) => {
                        return Ok(ProbeDecision::Busy(circuit.snapshot));
                    }
                    State::HalfOpen => None,
                };
                let token = circuit.next_token()?;
                if let Some(generation) = half_opening {
                    circuit.transition(State::HalfOpen, generation);
                    circuit.snapshot.retry_at = None;
                }
                circuit.next_token = token;
                let granted = ProbeLease {
                    generation: circuit.snapshot.generation,
                    token,
                    expires_at: now.saturating_add(lease),
                };
                circuit.probe = Some(granted);
                circuit.snapshot.probe_expires_at = Some(granted.expires_at);
                Ok(ProbeDecision::Acquired {
                    lease: granted,
                    snapshot: circuit.snapshot,
                    transition: half_opening.map(|_| StateTransition::HalfOpened),
                })
            })
        })
    }

    fn complete_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease: ProbeLease,
        outcome: StoredOutcome,
        took: Duration,
        policy: ProbePolicy,
    ) -> StorageFuture<'a, StorageUpdate> {
        Box::pin(async move {
            self.with_circuit(circuit_name, |circuit, now| {
                let current = circuit.snapshot.state == State::HalfOpen
                    && circuit.snapshot.generation == lease.generation
                    && circuit
                        .probe
                        .is_some_and(|held| held.token == lease.token && held.expires_at > now);
                if !current {
                    return Ok(StorageUpdate {
                        snapshot: circuit.snapshot,
                        transition: None,
                        applied: Applied::Stale,
                    });
                }
                let successes = circuit.snapshot.consecutive_successes.saturating_add(1);
                let transition = match outcome {
                    StoredOutcome::Success if successes >= policy.success_threshold.get() => {
                        Some(StateTransition::Closed)
                    }
                    StoredOutcome::Failure => Some(StateTransition::Opened),
                    StoredOutcome::Success | StoredOutcome::Ignored => None,
                };
                let generation = transition.map(|_| circuit.next_generation()).transpose()?;
                circuit.push(MemoryCircuit::event(outcome, now, took), self.cap);
                circuit.probe = None;
                circuit.snapshot.probe_expires_at = None;
                match (outcome, generation) {
                    (StoredOutcome::Success, Some(generation)) => circuit.close(generation),
                    (StoredOutcome::Success, None) => {
                        circuit.snapshot.consecutive_successes = successes;
                    }
                    (StoredOutcome::Failure, Some(generation)) => {
                        circuit.open(now, policy.cooldown, generation);
                    }
                    (StoredOutcome::Failure, None) => {
                        debug_assert!(false, "a failed probe always takes a generation");
                    }
                    (StoredOutcome::Ignored, _) => {}
                }
                Ok(StorageUpdate {
                    snapshot: circuit.snapshot,
                    transition,
                    applied: Applied::Current,
                })
            })
        })
    }

    fn reset<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot> {
        Box::pin(async move {
            self.with_circuit(circuit_name, |circuit, _| {
                circuit.close(circuit.next_generation()?);
                Ok(circuit.snapshot)
            })
        })
    }
}

#[cfg(test)]
mod tests;
