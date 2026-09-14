//! Callback system for circuit breaker state transitions

use alloc::sync::Arc;

/// Type alias for circuit breaker callback functions
pub type CallbackFn = Arc<dyn Fn(&str) + Send + Sync>;

/// Callbacks for circuit breaker events
#[derive(Clone)]
pub struct Callbacks {
    pub on_open: Option<CallbackFn>,
    pub on_close: Option<CallbackFn>,
    pub on_half_open: Option<CallbackFn>,
}

impl Callbacks {
    pub fn new() -> Self {
        Self {
            on_open: None,
            on_close: None,
            on_half_open: None,
        }
    }

    /// Invoke an optional callback safely, catching any panics to prevent
    /// unwinding across FFI boundaries.
    fn trigger(callback: &Option<CallbackFn>, circuit: &str) {
        if let Some(callback) = callback {
            #[cfg(feature = "std")]
            {
                let cb = std::panic::AssertUnwindSafe(callback);
                let _ = std::panic::catch_unwind(|| cb(circuit));
            }
            #[cfg(not(feature = "std"))]
            callback(circuit);
        }
    }

    /// Trigger the on_open callback safely.
    pub fn trigger_open(&self, circuit: &str) {
        Self::trigger(&self.on_open, circuit);
    }

    /// Trigger the on_close callback safely.
    pub fn trigger_close(&self, circuit: &str) {
        Self::trigger(&self.on_close, circuit);
    }

    /// Trigger the on_half_open callback safely.
    pub fn trigger_half_open(&self, circuit: &str) {
        Self::trigger(&self.on_half_open, circuit);
    }
}

impl Default for Callbacks {
    fn default() -> Self {
        Self::new()
    }
}

impl core::fmt::Debug for Callbacks {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Callbacks")
            .field("on_open", &self.on_open.is_some())
            .field("on_close", &self.on_close.is_some())
            .field("on_half_open", &self.on_half_open.is_some())
            .finish()
    }
}

#[cfg(test)]
mod tests;
