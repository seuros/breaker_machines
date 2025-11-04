//! Storage backends for circuit breaker events
//!
//! This module provides different storage implementations:
//! - `MemoryStorage`: Thread-safe in-memory storage with sliding window
//! - `NullStorage`: No-op storage for testing and benchmarking

use crate::{Event, EventKind};
use std::collections::HashMap;
use std::sync::RwLock;
use std::time::Instant;

/// Abstract storage backend for circuit breaker events
pub trait StorageBackend: Send + Sync + std::fmt::Debug {
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

/// Thread-safe in-memory storage for circuit breaker events
#[derive(Debug)]
pub struct MemoryStorage {
    /// Events keyed by circuit name
    events: RwLock<HashMap<String, Vec<Event>>>,
    /// Maximum events to keep per circuit
    max_events: usize,
    /// Monotonic time anchor (prevents clock skew issues from NTP)
    start_time: Instant,
}

impl MemoryStorage {
    /// Create a new storage instance
    pub fn new() -> Self {
        Self::with_max_events(1000)
    }

    /// Create storage with custom max events per circuit
    pub fn with_max_events(max_events: usize) -> Self {
        Self {
            events: RwLock::new(HashMap::new()),
            max_events,
            start_time: Instant::now(),
        }
    }

    // Private helper methods

    fn record_event(&self, circuit_name: &str, kind: EventKind, duration: f64) {
        let mut events = self.events.write().unwrap();
        let circuit_events = events.entry(circuit_name.to_string()).or_default();

        circuit_events.push(Event {
            kind,
            timestamp: self.monotonic_time(),
            duration,
        });

        // Cleanup old events if we exceed max_events
        if circuit_events.len() > self.max_events {
            // Remove oldest 10% to avoid cleanup on every event
            // Ensure we remove at least 1 event even with small max_events
            let remove_count = (self.max_events / 10).max(1);
            circuit_events.drain(0..remove_count);
        }
    }

    fn count_events(&self, circuit_name: &str, kind: EventKind, window_seconds: f64) -> usize {
        let events = self.events.read().unwrap();
        let cutoff = self.monotonic_time() - window_seconds;

        events
            .get(circuit_name)
            .map(|ev| {
                ev.iter()
                    .filter(|e| e.kind == kind && e.timestamp >= cutoff)
                    .count()
            })
            .unwrap_or(0)
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
        let mut events = self.events.write().unwrap();
        events.remove(circuit_name);
    }

    fn clear_all(&self) {
        let mut events = self.events.write().unwrap();
        events.clear();
    }

    fn event_log(&self, circuit_name: &str, limit: usize) -> Vec<Event> {
        let events = self.events.read().unwrap();
        events
            .get(circuit_name)
            .map(|ev| {
                let start = if ev.len() > limit {
                    ev.len() - limit
                } else {
                    0
                };
                ev[start..].to_vec()
            })
            .unwrap_or_default()
    }

    fn monotonic_time(&self) -> f64 {
        self.start_time.elapsed().as_secs_f64()
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
    start_time: Instant,
}

impl NullStorage {
    /// Create a new null storage instance
    pub fn new() -> Self {
        Self {
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
        self.start_time.elapsed().as_secs_f64()
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

        let events = storage.events.read().unwrap();
        let circuit_events = events.get("test_circuit").unwrap();

        assert!(circuit_events.len() <= 100);
    }

    #[test]
    fn test_memory_storage_small_max_events() {
        let storage = MemoryStorage::with_max_events(5);

        for i in 0..20 {
            storage.record_success("test_circuit", i as f64 * 0.01);
        }

        let events = storage.events.read().unwrap();
        let circuit_events = events.get("test_circuit").unwrap();

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
