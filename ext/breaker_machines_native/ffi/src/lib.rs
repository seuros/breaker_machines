//! Ruby FFI bindings for breaker_machines
//!
//! This crate provides Magnus-based Ruby bindings for the breaker-machines library.
//! It exposes:
//! - Thread-safe storage backend for circuit breaker event tracking
//! - Complete circuit breaker with state machine
//!
//! The extension is Ractor-safe. `Storage` is `Sync`, so a frozen instance
//! (`Ractor.make_shareable(storage)`) can be shared between Ractors. `Circuit`
//! holds a `RefCell` and stays local to the Ractor that created it.

use breaker_machines::{CircuitBreaker, Config, EventKind, MemoryStorage, StorageBackend};
use magnus::{Error, Module, Object, RArray, RHash, Ruby, TryConvert, function, method};
use std::cell::RefCell;
use std::sync::Arc;

/// Ruby wrapper for the native storage backend
#[magnus::wrap(
    class = "BreakerMachinesNative::Storage",
    free_immediately,
    size,
    frozen_shareable
)]
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
    fn event_log(
        ruby: &Ruby,
        storage: &RubyStorage,
        circuit_name: String,
        limit: usize,
    ) -> Result<RArray, Error> {
        let events = storage.inner.event_log(&circuit_name, limit);
        let array = ruby.ary_new_capa(events.len());

        for event in events {
            let hash = ruby.hash_new_capa(3);
            let kind = match event.kind {
                EventKind::Success => "success",
                EventKind::Failure => "failure",
            };

            hash.aset(ruby.to_symbol("type"), kind)?;
            hash.aset(ruby.to_symbol("timestamp"), event.timestamp)?;
            hash.aset(
                ruby.to_symbol("duration_ms"),
                (event.duration * 1000.0).round(),
            )?;
            array.push(hash)?;
        }

        Ok(array)
    }
}

/// Ruby wrapper for the native circuit breaker
#[magnus::wrap(class = "BreakerMachinesNative::Circuit", free_immediately, size)]
struct RubyCircuit {
    inner: RefCell<CircuitBreaker>,
}

/// Read an optional config entry. Missing keys and `nil` yield `None`; a
/// value of the wrong type raises `TypeError` rather than being ignored.
fn config_value<T: TryConvert>(ruby: &Ruby, config: RHash, key: &str) -> Result<Option<T>, Error> {
    config.lookup(ruby.to_symbol(key))
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
    ///   - jitter_factor: Cooldown jitter, 0.0-1.0 (default: 0.0)
    ///   - failure_rate_threshold: Failure ratio that opens the circuit (default: none)
    ///   - minimum_calls: Calls required before the rate applies (default: 20)
    fn new(ruby: &Ruby, name: String, config: RHash) -> Result<Self, Error> {
        let half_open_timeout_secs =
            config_value(ruby, config, "half_open_timeout_secs")?.unwrap_or(30.0);

        let config = Config {
            failure_threshold: Some(config_value(ruby, config, "failure_threshold")?.unwrap_or(5)),
            failure_rate_threshold: config_value(ruby, config, "failure_rate_threshold")?,
            minimum_calls: config_value(ruby, config, "minimum_calls")?.unwrap_or(20),
            failure_window_secs: config_value(ruby, config, "failure_window_secs")?.unwrap_or(60.0),
            half_open_timeout_secs,
            success_threshold: config_value(ruby, config, "success_threshold")?.unwrap_or(2),
            probe_timeout_secs: half_open_timeout_secs,
            jitter_factor: config_value(ruby, config, "jitter_factor")?.unwrap_or(0.0),
        };

        Ok(Self {
            inner: RefCell::new(CircuitBreaker::new(name, config)),
        })
    }

    /// Record a successful operation
    fn record_success(&self, duration: f64) {
        self.inner
            .borrow_mut()
            .record_success_and_maybe_close(duration);
    }

    /// Record a failed operation and attempt to trip the circuit
    fn record_failure(&self, duration: f64) {
        self.inner
            .borrow_mut()
            .record_failure_and_maybe_trip(duration);
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
    // Must precede every method definition: Ruby marks methods Ractor-safe as
    // they are defined. Nothing below touches process-global mutable state.
    // SAFETY: called on the loading thread during extension initialisation.
    unsafe { rb_sys::rb_ext_ractor_safe(true) };

    let module = ruby.define_module("BreakerMachinesNative")?;

    let storage_class = module.define_class("Storage", ruby.class_object())?;
    storage_class.define_singleton_method("new", function!(RubyStorage::new, 0))?;
    storage_class.define_method("record_success", method!(RubyStorage::record_success, 2))?;
    storage_class.define_method("record_failure", method!(RubyStorage::record_failure, 2))?;
    storage_class.define_method("success_count", method!(RubyStorage::success_count, 2))?;
    storage_class.define_method("failure_count", method!(RubyStorage::failure_count, 2))?;
    storage_class.define_method("clear", method!(RubyStorage::clear, 1))?;
    storage_class.define_method("clear_all", method!(RubyStorage::clear_all, 0))?;
    storage_class.define_method("event_log", method!(RubyStorage::event_log, 2))?;

    let circuit_class = module.define_class("Circuit", ruby.class_object())?;
    circuit_class.define_singleton_method("new", function!(RubyCircuit::new, 2))?;
    circuit_class.define_method("record_success", method!(RubyCircuit::record_success, 1))?;
    circuit_class.define_method("record_failure", method!(RubyCircuit::record_failure, 1))?;
    circuit_class.define_method("is_open", method!(RubyCircuit::is_open, 0))?;
    circuit_class.define_method("is_closed", method!(RubyCircuit::is_closed, 0))?;
    circuit_class.define_method("state_name", method!(RubyCircuit::state_name, 0))?;
    circuit_class.define_method("reset", method!(RubyCircuit::reset, 0))?;

    Ok(())
}
