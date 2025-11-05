//! Callback system for circuit breaker state transitions

use std::sync::Arc;

/// Callbacks for circuit breaker events
#[derive(Clone)]
pub struct Callbacks {
    pub on_open: Option<Arc<dyn Fn(&str) + Send + Sync>>,
    pub on_close: Option<Arc<dyn Fn(&str) + Send + Sync>>,
    pub on_half_open: Option<Arc<dyn Fn(&str) + Send + Sync>>,
}

impl Callbacks {
    pub fn new() -> Self {
        Self {
            on_open: None,
            on_close: None,
            on_half_open: None,
        }
    }

    pub fn trigger_open(&self, circuit: &str) {
        if let Some(ref callback) = self.on_open {
            callback(circuit);
        }
    }

    pub fn trigger_close(&self, circuit: &str) {
        if let Some(ref callback) = self.on_close {
            callback(circuit);
        }
    }

    pub fn trigger_half_open(&self, circuit: &str) {
        if let Some(ref callback) = self.on_half_open {
            callback(circuit);
        }
    }
}

impl Default for Callbacks {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for Callbacks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Callbacks")
            .field("on_open", &self.on_open.is_some())
            .field("on_close", &self.on_close.is_some())
            .field("on_half_open", &self.on_half_open.is_some())
            .finish()
    }
}
