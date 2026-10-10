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
use breaker_machines::{
    CircuitBreaker, CircuitError, Config, EventKind, MemoryStorage, StorageBackend,
};
use magnus::value::ReprValue;
use magnus::{
    Class, Error, ExceptionClass, Module, Object, RArray, RHash, RModule, RString, Ruby,
    TryConvert, Value, function, method,
};
use std::borrow::Cow;
use std::cell::RefCell;
use std::convert::Infallible;
use std::sync::Arc;

/// Fallback for `BreakerMachines::CircuitOpenError` when only the extension is
/// loaded; same constructor, so both are raised the same way.
const NATIVE_OPEN_ERROR: &str = r#"
module BreakerMachinesNative
  class CircuitOpenError < StandardError
    attr_reader :circuit_name, :opened_at

    def initialize(circuit_name, opened_at = nil)
      @circuit_name = circuit_name
      @opened_at = opened_at
      super("Circuit '#{circuit_name}' is open")
    end
  end
end
"#;

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

/// [`CircuitState`] as the pure-Ruby circuit names it (`:half_open`).
const fn ruby_state_name(state: CircuitState) -> &'static str {
    match state {
        CircuitState::Closed => "closed",
        CircuitState::Open => "open",
        CircuitState::HalfOpen => "half_open",
    }
}

/// A rejected admission, copied out of the circuit so the Ruby exception can
/// be built after its `RefCell` borrow has ended.
#[derive(Debug)]
enum Rejection {
    /// Open, or `HalfOpen` with every probe slot taken. `age` is how long ago
    /// the circuit opened; `HalfOpenLimitReached` does not carry it.
    Open {
        circuit: Arc<str>,
        age: Option<f64>,
    },
    BulkheadFull {
        circuit: Arc<str>,
        limit: usize,
    },
    /// A local circuit has no storage errors; kept for exhaustiveness.
    Other(String),
}

impl Rejection {
    fn new(error: CircuitError<Infallible>, now: f64) -> Self {
        match error {
            CircuitError::Open { circuit, opened_at } => Self::Open {
                circuit,
                age: Some(now - opened_at),
            },
            CircuitError::HalfOpenLimitReached { circuit } => Self::Open { circuit, age: None },
            CircuitError::BulkheadFull { circuit, limit } => Self::BulkheadFull { circuit, limit },
            CircuitError::Storage(error) => Self::Other(error.to_string()),
            CircuitError::Execution(never) => match never {},
        }
    }

    /// The exception the pure-Ruby circuit raises for the same rejection.
    fn into_error(self, ruby: &Ruby) -> Error {
        let exception = match self {
            Self::Open { circuit, age } => open_error_class(ruby).and_then(|class| {
                // `opened_at` in Ruby's clock, as the pure-Ruby circuit stores it.
                let opened_at = age.map(|age| ruby_monotonic_time(ruby).map(|now| now - age));
                class.new_instance((&*circuit, opened_at.transpose()?))
            }),
            Self::BulkheadFull { circuit, limit } => {
                let Some(class) = breaker_machines_error(ruby, "CircuitBulkheadError") else {
                    let message = format!("Circuit '{circuit}' bulkhead is full (limit: {limit})");
                    return Error::new(ruby.exception_runtime_error(), message);
                };
                class.new_instance((&*circuit, limit))
            }
            Self::Other(message) => return Error::new(ruby.exception_runtime_error(), message),
        };
        // Failing to build the exception raises that failure instead.
        exception.map_or_else(|error| error, Error::from)
    }
}

/// `BreakerMachines::<name>` when the gem is loaded, looked up per call so it
/// works whichever was required first.
fn breaker_machines_error(ruby: &Ruby, name: &str) -> Option<ExceptionClass> {
    // Not loaded is the expected case for the extension alone, not an error.
    let namespace: RModule = ruby.class_object().const_get("BreakerMachines").ok()?;
    namespace.const_get(name).ok()
}

fn open_error_class(ruby: &Ruby) -> Result<ExceptionClass, Error> {
    match breaker_machines_error(ruby, "CircuitOpenError") {
        Some(class) => Ok(class),
        None => ruby
            .class_object()
            .const_get::<_, RModule>("BreakerMachinesNative")?
            .const_get("CircuitOpenError"),
    }
}

/// `Process.clock_gettime(Process::CLOCK_MONOTONIC)`, the clock behind
/// `BreakerMachines.monotonic_time`.
fn ruby_monotonic_time(ruby: &Ruby) -> Result<f64, Error> {
    let process = ruby.module_process();
    let clock: Value = process.const_get("CLOCK_MONOTONIC")?;
    process.funcall("clock_gettime", (clock,))
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

    /// Check if circuit is half-open
    fn is_half_open(&self) -> bool {
        self.inner.borrow().state() == CircuitState::HalfOpen
    }

    /// Run the block under circuit protection, like the pure-Ruby circuit.
    ///
    /// The circuit is borrowed only to admit and to record the outcome, never
    /// while the block runs, so the block may re-enter this circuit and other
    /// threads may use it while the block waits on IO. A `StandardError`
    /// counts as a failure and is re-raised unchanged; other exceptions and
    /// `throw`/`break` pass through without counting.
    fn call(ruby: &Ruby, circuit: &Self) -> Result<Value, Error> {
        if !ruby.block_given() {
            return Err(Error::new(
                ruby.exception_local_jump_error(),
                "no block given (yield)",
            ));
        }

        let admission = {
            let mut inner = circuit.inner.borrow_mut();
            inner
                .try_acquire()
                .map_err(|error| Rejection::new(error, inner.monotonic_time()))
        };
        let ticket = admission.map_err(|rejection| rejection.into_error(ruby))?;

        let result = ruby.yield_values::<(), Value>(());

        if let Err(error) = &result
            && !error.is_kind_of(ruby.exception_standard_error())
        {
            circuit.inner.borrow_mut().abandon(ticket);
            return result;
        }
        let outcome = circuit.inner.borrow_mut().complete(ticket, result);
        outcome.map_err(|error| match error {
            CircuitError::Execution(error) => error,
            other => Error::new(ruby.exception_runtime_error(), other.to_string()),
        })
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
    let _: Value = ruby.eval(NATIVE_OPEN_ERROR)?;

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
    circuit_class.define_method("is_half_open", method!(RubyCircuit::is_half_open, 0))?;
    circuit_class.define_method("call", method!(RubyCircuit::call, 0))?;
    circuit_class.define_method("state_name", method!(RubyCircuit::state_name, 0))?;
    circuit_class.define_method("reset", method!(RubyCircuit::reset, 0))?;

    Ok(())
}

#[cfg(test)]
mod tests;
