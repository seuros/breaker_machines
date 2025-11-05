//! Ruby FFI bindings for breaker_machines
//!
//! This crate provides Magnus-based Ruby bindings for the breaker-machines library.
//! It exposes:
//! - Thread-safe storage backend for circuit breaker event tracking
//! - Complete circuit breaker with state machine

use breaker_machines::{CircuitBreaker, Config, EventKind, MemoryStorage, StorageBackend};
use magnus::{Error, Module, Object, RArray, RHash, Ruby, function, method};
use std::sync::Arc;

/// Ruby wrapper for the native storage backend
#[magnus::wrap(class = "BreakerMachinesNative::Storage")]
struct RubyStorage {
    inner: Arc<MemoryStorage>,
}

impl RubyStorage {
    /// Create a new storage instance
    fn new() -> Self {
        Self {
            inner: Arc::new(MemoryStorage::new()),
        }
    }

    /// Record a successful operation
    fn record_success(&self, circuit_name: String, duration: f64) {
        self.inner.record_success(&circuit_name, duration);
    }

    /// Record a failed operation
    fn record_failure(&self, circuit_name: String, duration: f64) {
        self.inner.record_failure(&circuit_name, duration);
    }

    /// Count successful operations within time window
    fn success_count(&self, circuit_name: String, window_seconds: f64) -> usize {
        self.inner.success_count(&circuit_name, window_seconds)
    }

    /// Count failed operations within time window
    fn failure_count(&self, circuit_name: String, window_seconds: f64) -> usize {
        self.inner.failure_count(&circuit_name, window_seconds)
    }

    /// Clear all events for a circuit
    fn clear(&self, circuit_name: String) {
        self.inner.clear(&circuit_name);
    }

    /// Clear all events for all circuits
    fn clear_all(&self) {
        self.inner.clear_all();
    }

    /// Get event log for a circuit (returns array of hashes)
    fn event_log(&self, circuit_name: String, limit: usize) -> RArray {
        let events = self.inner.event_log(&circuit_name, limit);
        let array = RArray::new();

        for event in events {
            // Create a Ruby hash for each event
            let hash = RHash::new();

            // Set event type
            let type_sym = match event.kind {
                EventKind::Success => "success",
                EventKind::Failure => "failure",
            };

            let _ = hash.aset(magnus::Symbol::new("type"), type_sym);
            let _ = hash.aset(magnus::Symbol::new("timestamp"), event.timestamp);
            let _ = hash.aset(
                magnus::Symbol::new("duration_ms"),
                (event.duration * 1000.0).round(),
            );

            let _ = array.push(hash);
        }

        array
    }
}

/// Ruby wrapper for the native circuit breaker
#[magnus::wrap(class = "BreakerMachinesNative::Circuit")]
struct RubyCircuit {
    inner: std::cell::RefCell<CircuitBreaker>,
}

impl RubyCircuit {
    /// Create a new circuit breaker
    ///
    /// @param name [String] Circuit name
    /// @param config [Hash] Configuration hash with keys:
    ///   - failure_threshold: Number of failures to open circuit (default: 5)
    ///   - failure_window_secs: Time window for counting failures (default: 60.0)
    ///   - half_open_timeout_secs: Timeout before attempting reset (default: 30.0)
    ///   - success_threshold: Successes needed to close from half-open (default: 2)
    fn new(name: String, config_hash: RHash) -> Result<Self, Error> {
        use magnus::TryConvert;

        // Extract config values with proper type conversion
        let failure_threshold: usize = config_hash
            .get(magnus::Symbol::new("failure_threshold"))
            .and_then(|v| usize::try_convert(v).ok())
            .unwrap_or(5);

        let failure_window_secs: f64 = config_hash
            .get(magnus::Symbol::new("failure_window_secs"))
            .and_then(|v| f64::try_convert(v).ok())
            .unwrap_or(60.0);

        let half_open_timeout_secs: f64 = config_hash
            .get(magnus::Symbol::new("half_open_timeout_secs"))
            .and_then(|v| f64::try_convert(v).ok())
            .unwrap_or(30.0);

        let success_threshold: usize = config_hash
            .get(magnus::Symbol::new("success_threshold"))
            .and_then(|v| usize::try_convert(v).ok())
            .unwrap_or(2);

        let jitter_factor: f64 = config_hash
            .get(magnus::Symbol::new("jitter_factor"))
            .and_then(|v| f64::try_convert(v).ok())
            .unwrap_or(0.0);

        let failure_rate_threshold: Option<f64> = config_hash
            .get(magnus::Symbol::new("failure_rate_threshold"))
            .and_then(|v| f64::try_convert(v).ok());

        let minimum_calls: usize = config_hash
            .get(magnus::Symbol::new("minimum_calls"))
            .and_then(|v| usize::try_convert(v).ok())
            .unwrap_or(20);

        let config = Config {
            failure_threshold: Some(failure_threshold),
            failure_rate_threshold,
            minimum_calls,
            failure_window_secs,
            half_open_timeout_secs,
            success_threshold,
            jitter_factor,
        };

        Ok(Self {
            inner: std::cell::RefCell::new(CircuitBreaker::new(name, config)),
        })
    }

    /// Record a successful operation
    fn record_success(&self, duration: f64) {
        self.inner.borrow().record_success(duration);
    }

    /// Record a failed operation and attempt to trip the circuit
    fn record_failure(&self, duration: f64) {
        let mut circuit = self.inner.borrow_mut();
        circuit.record_failure(duration);
        circuit.check_and_trip();
    }

    /// Check if circuit is open
    fn is_open(&self) -> bool {
        self.inner.borrow().is_open()
    }

    /// Check if circuit is closed
    fn is_closed(&self) -> bool {
        self.inner.borrow().is_closed()
    }

    /// Get current state name (lowercase for Ruby compatibility)
    fn state_name(&self) -> String {
        self.inner.borrow().state_name().to_lowercase()
    }

    /// Reset the circuit (clear all events)
    fn reset(&self) {
        self.inner.borrow_mut().reset();
    }
}

/// Initialize the Ruby extension
#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    // Create BreakerMachinesNative module
    let module = ruby.define_module("BreakerMachinesNative")?;

    // Define Storage class
    let storage_class = module.define_class("Storage", ruby.class_object())?;

    // Storage instance methods
    storage_class.define_singleton_method("new", function!(RubyStorage::new, 0))?;
    storage_class.define_method("record_success", method!(RubyStorage::record_success, 2))?;
    storage_class.define_method("record_failure", method!(RubyStorage::record_failure, 2))?;
    storage_class.define_method("success_count", method!(RubyStorage::success_count, 2))?;
    storage_class.define_method("failure_count", method!(RubyStorage::failure_count, 2))?;
    storage_class.define_method("clear", method!(RubyStorage::clear, 1))?;
    storage_class.define_method("clear_all", method!(RubyStorage::clear_all, 0))?;
    storage_class.define_method("event_log", method!(RubyStorage::event_log, 2))?;

    // Define Circuit class
    let circuit_class = module.define_class("Circuit", ruby.class_object())?;

    // Circuit instance methods
    circuit_class.define_singleton_method("new", function!(RubyCircuit::new, 2))?;
    circuit_class.define_method("record_success", method!(RubyCircuit::record_success, 1))?;
    circuit_class.define_method("record_failure", method!(RubyCircuit::record_failure, 1))?;
    circuit_class.define_method("is_open", method!(RubyCircuit::is_open, 0))?;
    circuit_class.define_method("is_closed", method!(RubyCircuit::is_closed, 0))?;
    circuit_class.define_method("state_name", method!(RubyCircuit::state_name, 0))?;
    circuit_class.define_method("reset", method!(RubyCircuit::reset, 0))?;

    Ok(())
}
