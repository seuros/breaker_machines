//! Hooks fired when a runtime circuit changes state.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

/// A hook receiving the circuit's name.
pub type CallbackFn = Arc<dyn Fn(&str) + Send + Sync>;

/// The hooks a runtime circuit fires on its transitions. A hook that panics
/// is contained: the transition it reports has already happened.
#[derive(Clone, Default)]
pub struct Callbacks {
    /// Fired when the circuit opens (threshold crossed, probe failed, or
    /// forced).
    pub on_open: Option<CallbackFn>,
    /// Fired when the circuit closes (probes succeeded, or forced).
    pub on_close: Option<CallbackFn>,
    /// Fired when an elapsed cooldown moves the circuit to half-open.
    pub on_half_open: Option<CallbackFn>,
}

impl Callbacks {
    pub(crate) fn fire(&self, transition: Transition, circuit: &str) {
        let hook = match transition {
            Transition::Opened => &self.on_open,
            Transition::Closed => &self.on_close,
            Transition::HalfOpened => &self.on_half_open,
        };
        if let Some(hook) = hook {
            // The payload is dropped on purpose: a hook's panic must neither
            // undo the transition nor unwind into the caller (or across FFI).
            drop(catch_unwind(AssertUnwindSafe(|| hook(circuit))));
        }
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

/// A transition a runtime call caused, in the order it happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transition {
    Opened,
    Closed,
    HalfOpened,
}

#[cfg(test)]
mod tests;
