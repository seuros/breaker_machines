//! Ruby FFI bindings for `breaker_machines`
//!
//! This crate provides Magnus-based Ruby bindings for the breaker-machines library.
//! It exposes:
//! - Thread-safe storage backend for circuit breaker event tracking
//! - Complete circuit breaker with state machine
//!
//! The extension is Ractor-safe. `Storage` is `Sync`, so a frozen instance
//! (`Ractor.make_shareable(storage)`) can be shared between Ractors. `Circuit`
//! holds a `RefCell` and stays local to the Ractor that created it.

use breaker_machines::circuit::CircuitState;
use breaker_machines::{CircuitBreaker, Config, EventKind, MemoryStorage, StorageBackend};
use magnus::{Error, Module, Object, RArray, RHash, RString, Ruby, TryConvert, function, method};
use std::borrow::Cow;
use std::cell::RefCell;
use std::sync::Arc;

/// Read a Ruby string as UTF-8, borrowing it in place whenever possible.
///
/// Accepts exactly what `String: TryConvert` does: UTF-8, US-ASCII, and 7-bit
/// ASCII-8BIT strings are borrowed without copying; any other encoding is
/// transcoded into an owned copy, raising `EncodingError` on failure.
///
/// # Safety
///
/// The borrowed variant points into memory owned by Ruby. While the returned
/// `Cow` is alive, the caller must not call any Ruby API or run Ruby code, so
/// that Ruby can neither mutate `string` nor run GC. Pure Rust work is fine:
/// this thread holds the GVL, so no other thread in this Ractor runs; other
/// Ractors cannot reach an unshareable string and cannot mutate a shareable
/// (frozen) one; and GC stops every Ractor at an interrupt check, which pure
/// Rust code never performs. Rust heap allocation goes to the system
/// allocator, never through Ruby (rb-sys's `global-allocator` feature is off).
/// `string` itself stays on the native stack, where Ruby's conservative stack
/// scan keeps it alive and pinned.
#[allow(unsafe_code)]
unsafe fn utf8_str(string: &RString) -> Result<Cow<'_, str>, Error> {
    // SAFETY: the caller upholds the contract above for as long as the
    // borrowed `&str` lives.
    if let Some(borrowed) = unsafe { string.test_as_str() } {
        return Ok(Cow::Borrowed(borrowed));
    }
    // Not borrowable: take magnus's transcoding path (the inherent
    // `RString::to_string`, not `ToString`). No borrow is alive here.
    RString::to_string(*string).map(Cow::Owned)
}

/// Lowercased [`CircuitState`] name, as Ruby has always received it
/// (`state_name().to_lowercase()`), without allocating per call.
const fn ruby_state_name(state: CircuitState) -> &'static str {
    match state {
        CircuitState::Closed => "closed",
        CircuitState::Open => "open",
        CircuitState::HalfOpen => "halfopen",
    }
}

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
    #[allow(unsafe_code)]
    fn record_success(&self, circuit_name: RString, duration: f64) -> Result<(), Error> {
        // SAFETY: only the pure-Rust `MemoryStorage` call runs while the name
        // is borrowed.
        let name = unsafe { utf8_str(&circuit_name) }?;
        self.inner.record_success(&name, duration);
        Ok(())
    }

    /// Record a failed operation
    #[allow(unsafe_code)]
    fn record_failure(&self, circuit_name: RString, duration: f64) -> Result<(), Error> {
        // SAFETY: only the pure-Rust `MemoryStorage` call runs while the name
        // is borrowed.
        let name = unsafe { utf8_str(&circuit_name) }?;
        self.inner.record_failure(&name, duration);
        Ok(())
    }

    /// Count successful operations within time window
    #[allow(unsafe_code)]
    fn success_count(&self, circuit_name: RString, window_seconds: f64) -> Result<usize, Error> {
        // SAFETY: only the pure-Rust `MemoryStorage` call runs while the name
        // is borrowed.
        let name = unsafe { utf8_str(&circuit_name) }?;
        Ok(self.inner.success_count(&name, window_seconds))
    }

    /// Count failed operations within time window
    #[allow(unsafe_code)]
    fn failure_count(&self, circuit_name: RString, window_seconds: f64) -> Result<usize, Error> {
        // SAFETY: only the pure-Rust `MemoryStorage` call runs while the name
        // is borrowed.
        let name = unsafe { utf8_str(&circuit_name) }?;
        Ok(self.inner.failure_count(&name, window_seconds))
    }

    /// Clear all events for a circuit
    #[allow(unsafe_code)]
    fn clear(&self, circuit_name: RString) -> Result<(), Error> {
        // SAFETY: only the pure-Rust `MemoryStorage` call runs while the name
        // is borrowed.
        let name = unsafe { utf8_str(&circuit_name) }?;
        self.inner.clear(&name);
        Ok(())
    }

    /// Clear all events for all circuits
    fn clear_all(&self) {
        self.inner.clear_all();
    }

    /// Get event log for a circuit (returns array of hashes)
    #[allow(unsafe_code)]
    fn event_log(
        ruby: &Ruby,
        storage: &Self,
        circuit_name: RString,
        limit: usize,
    ) -> Result<RArray, Error> {
        let events = {
            // SAFETY: the name is borrowed only for the pure-Rust lookup; the
            // borrow ends before any Ruby object is allocated below.
            let name = unsafe { utf8_str(&circuit_name) }?;
            storage.inner.event_log(&name, limit)
        };

        // Interned once per call (no Ruby allocation), not three times per event.
        let type_key = ruby.sym_new("type");
        let timestamp_key = ruby.sym_new("timestamp");
        let duration_key = ruby.sym_new("duration_ms");
        let array = ruby.ary_new_capa(events.len());

        for event in &events {
            let hash = ruby.hash_new_capa(3);
            let kind = match event.kind {
                EventKind::Success => "success",
                EventKind::Failure => "failure",
            };

            hash.aset(type_key, kind)?;
            hash.aset(timestamp_key, event.timestamp)?;
            hash.aset(duration_key, (event.duration * 1000.0).round())?;
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
    // `sym_new` interns the key; `to_symbol` would allocate a Ruby String first.
    config.lookup(ruby.sym_new(key))
}

impl RubyCircuit {
    /// Create a new circuit breaker
    ///
    /// @param name [String] Circuit name
    /// @param config [Hash] Configuration hash with keys:
    ///   - `failure_threshold`: Number of failures to open circuit (default: 5)
    ///   - `failure_window_secs`: Time window for counting failures (default: 60.0)
    ///   - `half_open_timeout_secs`: Timeout before attempting reset (default: 30.0)
    ///   - `success_threshold`: Successes needed to close from half-open (default: 2)
    ///   - `jitter_factor`: Cooldown jitter, 0.0-1.0 (default: 0.0)
    ///   - `failure_rate_threshold`: Failure ratio that opens the circuit (default: none)
    ///   - `minimum_calls`: Calls required before the rate applies (default: 20)
    #[allow(unsafe_code)]
    fn new(ruby: &Ruby, name: RString, config: RHash) -> Result<Self, Error> {
        // Copied straight into the circuit's `Arc<str>` (one allocation, not a
        // `String` and then an `Arc`), before the config is read so encoding
        // errors keep raising first.
        // SAFETY: the name is borrowed only while it is copied; no Ruby call
        // happens until the borrow has ended.
        let name: Arc<str> = Arc::from(&*unsafe { utf8_str(&name) }?);
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
    fn state_name(&self) -> &'static str {
        ruby_state_name(self.inner.borrow().state())
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
    #[allow(unsafe_code)]
    unsafe {
        rb_sys::rb_ext_ractor_safe(true);
    }

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

#[cfg(test)]
mod tests;
