//! Storage backends for local metrics and distributed circuit state.
//!
//! This module provides different storage implementations:
//! - [`StorageBackend`]: the legacy synchronous event store used by
//!   [`CircuitBreaker`](crate::CircuitBreaker)
//! - `AsyncStorageBackend`: an asynchronous, state-level contract for
//!   distributed circuit breakers
//! - [`MemoryStorage`]: an atomic in-memory implementation of both contracts
//! - [`NullStorage`]: no-op event storage for testing and benchmarking

use crate::time::Clock;
#[cfg(feature = "std")]
use crate::time::SystemClock;
#[cfg(not(feature = "std"))]
use crate::time::ZeroClock;
use crate::{Event, EventKind};
use alloc::boxed::Box;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use core::fmt;
#[cfg(feature = "async")]
use core::future::Future;
#[cfg(feature = "async")]
use core::pin::Pin;
use hashbrown::HashMap;
use spin::{RwLock, RwLockReadGuard, RwLockWriteGuard};
#[cfg(feature = "std")]
use std::time::Instant;

fn default_clock() -> Box<dyn Clock> {
    #[cfg(feature = "std")]
    {
        Box::new(SystemClock::new())
    }
    #[cfg(not(feature = "std"))]
    {
        Box::new(ZeroClock)
    }
}

/// State shared by every gateway using a distributed circuit store.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SharedCircuitState {
    /// Calls are admitted normally.
    #[default]
    Closed,
    /// Calls are rejected until the storage-owned retry timestamp is reached.
    Open,
    /// A recovery probe may be elected by the store.
    HalfOpen,
}

impl SharedCircuitState {
    /// Stable state name for diagnostics and fallbacks.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Closed => "Closed",
            Self::Open => "Open",
            Self::HalfOpen => "HalfOpen",
        }
    }
}

/// Authoritative state returned by a distributed storage backend.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct CircuitSnapshot {
    /// Current shared FSM state.
    pub state: SharedCircuitState,
    /// Fencing generation. It changes on every state transition or reset.
    pub generation: u64,
    /// Storage-clock timestamp at which the current open cycle began.
    pub opened_at: Option<f64>,
    /// Storage-clock timestamp at which an open circuit may elect a probe.
    pub retry_at: Option<f64>,
    /// Successful probes accumulated in the current half-open generation.
    pub consecutive_successes: usize,
    /// Expiry of the currently elected probe, if one exists.
    pub probe_expires_at: Option<f64>,
}

/// Fenced lease granting one node permission to execute a half-open probe.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProbeLease {
    /// Half-open generation for which this lease is valid.
    pub generation: u64,
    /// Store-issued fencing token.
    pub token: u64,
    /// Storage-clock timestamp after which another node may take the lease.
    pub expires_at: f64,
}

/// Result of the atomic [`AsyncStorageBackend::try_begin_probe`] operation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProbeDecision {
    /// The circuit became closed while admission was in progress.
    Closed(CircuitSnapshot),
    /// Cooldown has not elapsed yet.
    Open(CircuitSnapshot),
    /// Another node currently owns the half-open probe lease.
    Busy(CircuitSnapshot),
    /// This caller won the probe election.
    Acquired {
        /// Fenced lease required to complete the probe.
        lease: ProbeLease,
        /// State after the lease was acquired.
        snapshot: CircuitSnapshot,
        /// Whether this operation performed the Open -> HalfOpen transition.
        transitioned: bool,
    },
}

/// Outcome recorded by a state-level storage operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoredOutcome {
    /// The protected operation succeeded.
    Success,
    /// The protected operation failed and counts toward opening the circuit.
    Failure,
    /// The failure classifier ignored the operation.
    Ignored,
}

/// Thresholds required for an atomic event record and possible open transition.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FailurePolicy {
    /// Absolute number of failures required to open.
    pub failure_threshold: Option<usize>,
    /// Failure ratio required to open.
    pub failure_rate_threshold: Option<f64>,
    /// Minimum number of calls before evaluating the failure ratio.
    pub minimum_calls: usize,
    /// Width of the rolling outcome window.
    pub failure_window_secs: f64,
    /// Delay between opening and probe eligibility. The winning store operation
    /// persists this duration against its own authoritative clock.
    pub open_timeout_secs: f64,
}

/// Policy applied when a fenced half-open probe completes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProbePolicy {
    /// Successful probes required before closing the circuit.
    pub success_threshold: usize,
    /// Delay before another probe after a failed probe reopens the circuit.
    pub open_timeout_secs: f64,
}

/// Shared transition won by a storage operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateTransition {
    /// Closed or HalfOpen -> Open.
    Opened,
    /// HalfOpen -> Closed.
    Closed,
}

/// Result of atomically recording an outcome or completing a probe.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StorageUpdate {
    /// State after the operation.
    pub snapshot: CircuitSnapshot,
    /// Transition performed by this operation, if any.
    pub transition: Option<StateTransition>,
    /// Whether the supplied generation or probe lease was still current.
    pub applied: bool,
}

/// Error returned by a distributed storage backend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageError {
    message: String,
}

impl StorageError {
    /// Create a storage error from a backend-specific message.
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Return the backend-provided message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for StorageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl core::error::Error for StorageError {}

/// Object-safe future returned by distributed storage operations.
#[cfg(feature = "async")]
pub type StorageFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, StorageError>> + Send + 'a>>;

/// Async, state-level storage contract for distributed circuit breakers.
///
/// Implementations must make each method atomic for a circuit key. In
/// particular, `record_outcome` must record the event and perform any open
/// transition in one transaction, while `try_begin_probe` must elect at most
/// one unexpired probe lease. All timestamps must come from the backend's
/// authoritative clock; callers never supply `opened_at` or `retry_at`.
#[cfg(feature = "async")]
pub trait AsyncStorageBackend: Send + Sync + fmt::Debug {
    /// Load the authoritative FSM state, returning Closed generation zero for a
    /// key that has not been seen before.
    fn load_state<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot>;

    /// Record a normal-call outcome and atomically open the circuit if the
    /// supplied generation is current and a threshold is crossed.
    fn record_outcome<'a>(
        &'a self,
        circuit_name: &'a str,
        generation: u64,
        outcome: StoredOutcome,
        duration: f64,
        policy: FailurePolicy,
    ) -> StorageFuture<'a, StorageUpdate>;

    /// Atomically check the storage-owned cooldown and elect one half-open
    /// probe. Leases must be fenced and expire according to the backend clock.
    fn try_begin_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease_ttl_secs: f64,
    ) -> StorageFuture<'a, ProbeDecision>;

    /// Complete a probe only if its generation and fencing token are current.
    /// Stale completions must not modify the control-plane rolling window,
    /// transition the FSM, or release a newer lease. Backends may emit them to
    /// a separate observability stream.
    fn complete_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease: ProbeLease,
        outcome: StoredOutcome,
        duration: f64,
        policy: ProbePolicy,
    ) -> StorageFuture<'a, StorageUpdate>;

    /// Reset metrics and shared state while advancing the fencing generation.
    fn reset<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot>;
}

/// Synchronous event backend for the process-local [`CircuitBreaker`](crate::CircuitBreaker).
///
/// This trait is intentionally not a distributed coordination API: it has no
/// shared FSM or atomic probe election. Use `AsyncStorageBackend` with
/// `DistributedCircuitBreaker` for that.
pub trait StorageBackend: Send + Sync + core::fmt::Debug {
    /// Record a successful operation
    fn record_success(&self, circuit_name: &str, duration: f64);

    /// Record a failed operation
    fn record_failure(&self, circuit_name: &str, duration: f64);

    /// Count successful operations within a time window
    fn success_count(&self, circuit_name: &str, window_seconds: f64) -> usize;

    /// Count failed operations within a time window
    fn failure_count(&self, circuit_name: &str, window_seconds: f64) -> usize;

    /// Clear all events for a circuit
    fn clear(&self, circuit_name: &str);

    /// Clear all events for all circuits
    fn clear_all(&self);

    /// Get event log for a circuit (limited to last N events)
    fn event_log(&self, circuit_name: &str, limit: usize) -> Vec<Event>;

    /// Get monotonic time in seconds (relative to storage creation)
    fn monotonic_time(&self) -> f64;
}

#[derive(Debug)]
#[cfg_attr(not(feature = "async"), allow(dead_code))]
struct MemoryCircuit {
    events: Vec<Event>,
    state: SharedCircuitState,
    generation: u64,
    opened_at: Option<f64>,
    retry_at: Option<f64>,
    consecutive_successes: usize,
    probe: Option<ProbeLease>,
    next_probe_token: u64,
}

impl Default for MemoryCircuit {
    fn default() -> Self {
        Self {
            events: Vec::new(),
            state: SharedCircuitState::Closed,
            generation: 0,
            opened_at: None,
            retry_at: None,
            consecutive_successes: 0,
            probe: None,
            next_probe_token: 0,
        }
    }
}

impl MemoryCircuit {
    #[cfg(feature = "async")]
    fn snapshot(&self) -> CircuitSnapshot {
        CircuitSnapshot {
            state: self.state,
            generation: self.generation,
            opened_at: self.opened_at,
            retry_at: self.retry_at,
            consecutive_successes: self.consecutive_successes,
            probe_expires_at: self.probe.map(|lease| lease.expires_at),
        }
    }

    #[cfg(feature = "async")]
    fn reset(&mut self) {
        let generation = self.generation.wrapping_add(1);
        let next_probe_token = self.next_probe_token;
        *self = Self {
            generation,
            next_probe_token,
            ..Self::default()
        };
    }
}

/// Thread-safe in-memory storage for events and authoritative circuit state.
#[derive(Debug)]
pub struct MemoryStorage {
    /// Metrics and shared state keyed by circuit name. One write lock makes
    /// event recording, threshold checks, transitions, and probe election
    /// atomic for the in-memory backend.
    circuits: RwLock<HashMap<String, MemoryCircuit>>,
    /// Maximum events to keep per circuit
    max_events: usize,
    /// Monotonic time source
    clock: Box<dyn Clock>,
}

impl MemoryStorage {
    /// Create a new storage instance
    pub fn new() -> Self {
        Self::with_max_events(1000)
    }

    /// Create storage with custom max events per circuit
    pub fn with_max_events(max_events: usize) -> Self {
        Self::with_max_events_and_clock(max_events, default_clock())
    }

    /// Create storage with a custom [`Clock`].
    pub fn with_clock(clock: Box<dyn Clock>) -> Self {
        Self::with_max_events_and_clock(1000, clock)
    }

    /// Create storage with both a custom event cap and time source.
    pub fn with_max_events_and_clock(max_events: usize, clock: Box<dyn Clock>) -> Self {
        Self {
            circuits: RwLock::new(HashMap::new()),
            max_events,
            clock,
        }
    }

    // Private helper methods

    fn circuits_read(&self) -> RwLockReadGuard<'_, HashMap<String, MemoryCircuit>> {
        self.circuits.read()
    }

    fn circuits_write(&self) -> RwLockWriteGuard<'_, HashMap<String, MemoryCircuit>> {
        self.circuits.write()
    }

    fn record_event(&self, circuit_name: &str, kind: EventKind, duration: f64) {
        let now = self.monotonic_time();
        let mut circuits = self.circuits_write();
        let circuit = circuits.entry(circuit_name.to_string()).or_default();
        Self::push_event(circuit, self.max_events, kind, now, duration);
    }

    fn count_events(&self, circuit_name: &str, kind: EventKind, window_seconds: f64) -> usize {
        let circuits = self.circuits_read();
        let cutoff = self.monotonic_time() - window_seconds;

        circuits
            .get(circuit_name)
            .map(|circuit| {
                circuit
                    .events
                    .iter()
                    .filter(|e| e.kind == kind && e.timestamp >= cutoff)
                    .count()
            })
            .unwrap_or(0)
    }

    fn push_event(
        circuit: &mut MemoryCircuit,
        max_events: usize,
        kind: EventKind,
        timestamp: f64,
        duration: f64,
    ) {
        circuit.events.push(Event {
            kind,
            timestamp,
            duration,
        });

        if circuit.events.len() > max_events {
            let remove_count = (max_events / 10).max(1);
            circuit.events.drain(0..remove_count);
        }
    }

    #[cfg(feature = "async")]
    fn failure_threshold_exceeded(
        circuit: &MemoryCircuit,
        now: f64,
        policy: FailurePolicy,
    ) -> bool {
        let cutoff = now - policy.failure_window_secs;
        let failures = circuit
            .events
            .iter()
            .filter(|event| event.kind == EventKind::Failure && event.timestamp >= cutoff)
            .count();

        if let Some(threshold) = policy.failure_threshold
            && failures >= threshold
        {
            return true;
        }

        if let Some(rate_threshold) = policy.failure_rate_threshold {
            let successes = circuit
                .events
                .iter()
                .filter(|event| event.kind == EventKind::Success && event.timestamp >= cutoff)
                .count();
            let total = failures + successes;

            if total >= policy.minimum_calls && total > 0 {
                return failures as f64 / total as f64 >= rate_threshold;
            }
        }

        false
    }

    #[cfg(feature = "async")]
    fn open(circuit: &mut MemoryCircuit, now: f64, timeout_secs: f64) {
        circuit.state = SharedCircuitState::Open;
        circuit.generation = circuit.generation.wrapping_add(1);
        circuit.opened_at = Some(now);
        circuit.retry_at = Some(now + timeout_secs.max(0.0));
        circuit.consecutive_successes = 0;
        circuit.probe = None;
    }
}

impl Default for MemoryStorage {
    fn default() -> Self {
        Self::new()
    }
}

impl StorageBackend for MemoryStorage {
    fn record_success(&self, circuit_name: &str, duration: f64) {
        self.record_event(circuit_name, EventKind::Success, duration);
    }

    fn record_failure(&self, circuit_name: &str, duration: f64) {
        self.record_event(circuit_name, EventKind::Failure, duration);
    }

    fn success_count(&self, circuit_name: &str, window_seconds: f64) -> usize {
        self.count_events(circuit_name, EventKind::Success, window_seconds)
    }

    fn failure_count(&self, circuit_name: &str, window_seconds: f64) -> usize {
        self.count_events(circuit_name, EventKind::Failure, window_seconds)
    }

    fn clear(&self, circuit_name: &str) {
        let mut circuits = self.circuits_write();
        circuits.remove(circuit_name);
    }

    fn clear_all(&self) {
        let mut circuits = self.circuits_write();
        circuits.clear();
    }

    fn event_log(&self, circuit_name: &str, limit: usize) -> Vec<Event> {
        let circuits = self.circuits_read();
        circuits
            .get(circuit_name)
            .map(|circuit| {
                let start = if circuit.events.len() > limit {
                    circuit.events.len() - limit
                } else {
                    0
                };
                circuit.events[start..].to_vec()
            })
            .unwrap_or_default()
    }

    fn monotonic_time(&self) -> f64 {
        self.clock.now_secs()
    }
}

#[cfg(feature = "async")]
impl AsyncStorageBackend for MemoryStorage {
    fn load_state<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot> {
        Box::pin(async move {
            let circuits = self.circuits_read();
            Ok(circuits
                .get(circuit_name)
                .map(MemoryCircuit::snapshot)
                .unwrap_or_default())
        })
    }

    fn record_outcome<'a>(
        &'a self,
        circuit_name: &'a str,
        generation: u64,
        outcome: StoredOutcome,
        duration: f64,
        policy: FailurePolicy,
    ) -> StorageFuture<'a, StorageUpdate> {
        Box::pin(async move {
            let now = self.monotonic_time();
            let mut circuits = self.circuits_write();
            let circuit = circuits.entry(circuit_name.to_string()).or_default();
            let applied = circuit.generation == generation;

            if applied {
                match outcome {
                    StoredOutcome::Success => Self::push_event(
                        circuit,
                        self.max_events,
                        EventKind::Success,
                        now,
                        duration,
                    ),
                    StoredOutcome::Failure => Self::push_event(
                        circuit,
                        self.max_events,
                        EventKind::Failure,
                        now,
                        duration,
                    ),
                    StoredOutcome::Ignored => {}
                }
            }

            let mut transition = None;
            if applied
                && circuit.state == SharedCircuitState::Closed
                && outcome == StoredOutcome::Failure
                && Self::failure_threshold_exceeded(circuit, now, policy)
            {
                Self::open(circuit, now, policy.open_timeout_secs);
                transition = Some(StateTransition::Opened);
            }

            Ok(StorageUpdate {
                snapshot: circuit.snapshot(),
                transition,
                applied,
            })
        })
    }

    fn try_begin_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease_ttl_secs: f64,
    ) -> StorageFuture<'a, ProbeDecision> {
        Box::pin(async move {
            let now = self.monotonic_time();
            let mut circuits = self.circuits_write();
            let circuit = circuits.entry(circuit_name.to_string()).or_default();
            let mut transitioned = false;

            match circuit.state {
                SharedCircuitState::Closed => {
                    return Ok(ProbeDecision::Closed(circuit.snapshot()));
                }
                SharedCircuitState::Open => {
                    if circuit.retry_at.is_some_and(|retry_at| now < retry_at) {
                        return Ok(ProbeDecision::Open(circuit.snapshot()));
                    }

                    circuit.state = SharedCircuitState::HalfOpen;
                    circuit.generation = circuit.generation.wrapping_add(1);
                    circuit.retry_at = None;
                    circuit.consecutive_successes = 0;
                    circuit.probe = None;
                    transitioned = true;
                }
                SharedCircuitState::HalfOpen => {}
            }

            if circuit.probe.is_some_and(|lease| lease.expires_at > now) {
                return Ok(ProbeDecision::Busy(circuit.snapshot()));
            }

            circuit.next_probe_token = circuit.next_probe_token.wrapping_add(1);
            let lease = ProbeLease {
                generation: circuit.generation,
                token: circuit.next_probe_token,
                expires_at: now + lease_ttl_secs.max(f64::EPSILON),
            };
            circuit.probe = Some(lease);

            Ok(ProbeDecision::Acquired {
                lease,
                snapshot: circuit.snapshot(),
                transitioned,
            })
        })
    }

    fn complete_probe<'a>(
        &'a self,
        circuit_name: &'a str,
        lease: ProbeLease,
        outcome: StoredOutcome,
        duration: f64,
        policy: ProbePolicy,
    ) -> StorageFuture<'a, StorageUpdate> {
        Box::pin(async move {
            let now = self.monotonic_time();
            let mut circuits = self.circuits_write();
            let circuit = circuits.entry(circuit_name.to_string()).or_default();

            let applied = circuit.state == SharedCircuitState::HalfOpen
                && circuit.generation == lease.generation
                && circuit.probe.is_some_and(|current| {
                    current.token == lease.token && current.expires_at > now
                });
            let mut transition = None;

            if applied {
                match outcome {
                    StoredOutcome::Success => Self::push_event(
                        circuit,
                        self.max_events,
                        EventKind::Success,
                        now,
                        duration,
                    ),
                    StoredOutcome::Failure => Self::push_event(
                        circuit,
                        self.max_events,
                        EventKind::Failure,
                        now,
                        duration,
                    ),
                    StoredOutcome::Ignored => {}
                }

                circuit.probe = None;
                match outcome {
                    StoredOutcome::Success => {
                        circuit.consecutive_successes += 1;
                        if circuit.consecutive_successes >= policy.success_threshold.max(1) {
                            circuit.state = SharedCircuitState::Closed;
                            circuit.generation = circuit.generation.wrapping_add(1);
                            circuit.opened_at = None;
                            circuit.retry_at = None;
                            circuit.consecutive_successes = 0;
                            circuit.events.clear();
                            transition = Some(StateTransition::Closed);
                        }
                    }
                    StoredOutcome::Failure => {
                        Self::open(circuit, now, policy.open_timeout_secs);
                        transition = Some(StateTransition::Opened);
                    }
                    StoredOutcome::Ignored => {}
                }
            }

            Ok(StorageUpdate {
                snapshot: circuit.snapshot(),
                transition,
                applied,
            })
        })
    }

    fn reset<'a>(&'a self, circuit_name: &'a str) -> StorageFuture<'a, CircuitSnapshot> {
        Box::pin(async move {
            let mut circuits = self.circuits_write();
            let circuit = circuits.entry(circuit_name.to_string()).or_default();
            circuit.reset();
            Ok(circuit.snapshot())
        })
    }
}

/// No-op storage backend for testing and benchmarking
///
/// This storage implementation discards all events and always returns zero counts.
/// Useful for:
/// - Testing circuit breaker logic without storage overhead
/// - Benchmarking pure state machine performance
/// - Scenarios where external systems track metrics
///
/// # Example
///
/// ```rust
/// use breaker_machines::{CircuitBreaker, NullStorage};
/// use std::sync::Arc;
///
/// let storage = Arc::new(NullStorage::new());
/// let mut circuit = CircuitBreaker::builder("test")
///     .storage(storage)
///     .build();
/// ```
#[derive(Debug, Clone, Copy)]
pub struct NullStorage {
    #[cfg(feature = "std")]
    start_time: Instant,
}

impl NullStorage {
    /// Create a new null storage instance
    pub fn new() -> Self {
        Self {
            #[cfg(feature = "std")]
            start_time: Instant::now(),
        }
    }
}

impl Default for NullStorage {
    fn default() -> Self {
        Self::new()
    }
}

impl StorageBackend for NullStorage {
    fn record_success(&self, _circuit_name: &str, _duration: f64) {
        // No-op
    }

    fn record_failure(&self, _circuit_name: &str, _duration: f64) {
        // No-op
    }

    fn success_count(&self, _circuit_name: &str, _window_seconds: f64) -> usize {
        0
    }

    fn failure_count(&self, _circuit_name: &str, _window_seconds: f64) -> usize {
        0
    }

    fn clear(&self, _circuit_name: &str) {
        // No-op
    }

    fn clear_all(&self) {
        // No-op
    }

    fn event_log(&self, _circuit_name: &str, _limit: usize) -> Vec<Event> {
        Vec::new()
    }

    fn monotonic_time(&self) -> f64 {
        #[cfg(feature = "std")]
        {
            self.start_time.elapsed().as_secs_f64()
        }
        #[cfg(not(feature = "std"))]
        {
            0.0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_memory_storage_record_and_count() {
        let storage = MemoryStorage::new();

        storage.record_success("test_circuit", 0.1);
        storage.record_success("test_circuit", 0.2);
        storage.record_failure("test_circuit", 0.5);

        assert_eq!(storage.success_count("test_circuit", 60.0), 2);
        assert_eq!(storage.failure_count("test_circuit", 60.0), 1);
    }

    #[test]
    fn test_memory_storage_clear() {
        let storage = MemoryStorage::new();

        storage.record_success("test_circuit", 0.1);
        assert_eq!(storage.success_count("test_circuit", 60.0), 1);

        storage.clear("test_circuit");
        assert_eq!(storage.success_count("test_circuit", 60.0), 0);
    }

    #[test]
    fn test_memory_storage_event_log() {
        let storage = MemoryStorage::new();

        storage.record_success("test_circuit", 0.1);
        storage.record_failure("test_circuit", 0.2);
        storage.record_success("test_circuit", 0.3);

        let log = storage.event_log("test_circuit", 10);
        assert_eq!(log.len(), 3);
        assert_eq!(log[0].kind, EventKind::Success);
        assert_eq!(log[1].kind, EventKind::Failure);
        assert_eq!(log[2].kind, EventKind::Success);
    }

    #[test]
    fn test_memory_storage_max_events_cleanup() {
        let storage = MemoryStorage::with_max_events(100);

        for i in 0..150 {
            storage.record_success("test_circuit", i as f64 * 0.01);
        }

        let circuits = storage.circuits.read();
        let circuit_events = &circuits.get("test_circuit").unwrap().events;

        assert!(circuit_events.len() <= 100);
    }

    #[test]
    fn test_memory_storage_small_max_events() {
        let storage = MemoryStorage::with_max_events(5);

        for i in 0..20 {
            storage.record_success("test_circuit", i as f64 * 0.01);
        }

        let circuits = storage.circuits.read();
        let circuit_events = &circuits.get("test_circuit").unwrap().events;

        assert!(
            circuit_events.len() <= 5,
            "Expected <= 5 events, got {}",
            circuit_events.len()
        );
    }

    #[test]
    fn test_memory_storage_monotonic_time() {
        let storage = MemoryStorage::new();

        storage.record_success("test_circuit", 0.1);
        let time1 = storage.monotonic_time();

        std::thread::sleep(std::time::Duration::from_millis(10));

        storage.record_success("test_circuit", 0.2);
        let time2 = storage.monotonic_time();

        assert!(time2 > time1);
        assert_eq!(storage.success_count("test_circuit", 1.0), 2);
    }

    #[test]
    fn test_null_storage_discards_events() {
        let storage = NullStorage::new();

        storage.record_success("test_circuit", 0.1);
        storage.record_failure("test_circuit", 0.2);

        assert_eq!(storage.success_count("test_circuit", 60.0), 0);
        assert_eq!(storage.failure_count("test_circuit", 60.0), 0);
    }

    #[test]
    fn test_null_storage_empty_event_log() {
        let storage = NullStorage::new();

        storage.record_success("test_circuit", 0.1);
        storage.record_failure("test_circuit", 0.2);

        let log = storage.event_log("test_circuit", 10);
        assert_eq!(log.len(), 0);
    }

    #[test]
    fn test_null_storage_clear_operations() {
        let storage = NullStorage::new();

        storage.clear("test_circuit");
        storage.clear_all();

        assert_eq!(storage.success_count("test_circuit", 60.0), 0);
    }

    #[test]
    fn test_null_storage_monotonic_time() {
        let storage = NullStorage::new();

        let time1 = storage.monotonic_time();
        std::thread::sleep(std::time::Duration::from_millis(10));
        let time2 = storage.monotonic_time();

        assert!(time2 > time1);
    }

    #[test]
    fn test_null_storage_with_circuit_breaker() {
        use std::sync::Arc;

        let storage = Arc::new(NullStorage::new());
        let mut circuit = crate::CircuitBreaker::builder("test")
            .storage(storage)
            .failure_threshold(3)
            .build();

        let _ = circuit.call(|| Err::<(), _>("error 1"));
        let _ = circuit.call(|| Err::<(), _>("error 2"));
        let _ = circuit.call(|| Err::<(), _>("error 3"));

        assert!(circuit.is_closed());
        assert!(!circuit.is_open());
    }
}
