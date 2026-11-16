//! Building a runtime circuit: its name, policy, clock, classifier and hooks.

use super::{CircuitBreaker, Core, Shared};
use crate::callbacks::{CallbackFn, Callbacks};
use crate::clock::{Clock, SystemClock};
use crate::{FailureClassifier, Policy};
#[cfg(feature = "async")]
use core::time::Duration;
use std::sync::Arc;

/// Builds a [`CircuitBreaker`] (or, with `async`, an
/// [`AsyncCircuitBreaker`](crate::AsyncCircuitBreaker) or a
/// [`DistributedCircuitBreaker`](crate::DistributedCircuitBreaker)).
#[must_use = "a builder does nothing until built"]
pub struct CircuitBuilder {
    name: Arc<str>,
    policy: Policy,
    scope: u16,
    clock: Option<Arc<dyn Clock>>,
    classifier: Option<Arc<dyn FailureClassifier>>,
    callbacks: Callbacks,
}

impl CircuitBuilder {
    pub(super) fn new(name: impl Into<Arc<str>>, policy: Policy) -> Self {
        Self {
            name: name.into(),
            policy,
            scope: 0,
            clock: None,
            classifier: None,
            callbacks: Callbacks::default(),
        }
    }

    /// Issue tickets in `scope` instead of zero.
    pub const fn scope(mut self, scope: u16) -> Self {
        self.scope = scope;
        self
    }

    /// Read `clock` instead of a [`SystemClock`] started at build time.
    pub fn clock(mut self, clock: impl Clock + 'static) -> Self {
        self.clock = Some(Arc::new(clock));
        self
    }

    /// Count only the failures `classifier` accepts.
    pub fn classifier(mut self, classifier: impl FailureClassifier + 'static) -> Self {
        self.classifier = Some(Arc::new(classifier));
        self
    }

    /// Fire `hook` when the circuit opens.
    pub fn on_open(mut self, hook: impl Fn(&str) + Send + Sync + 'static) -> Self {
        self.callbacks.on_open = Some(hook_fn(hook));
        self
    }

    /// Fire `hook` when the circuit closes.
    pub fn on_close(mut self, hook: impl Fn(&str) + Send + Sync + 'static) -> Self {
        self.callbacks.on_close = Some(hook_fn(hook));
        self
    }

    /// Fire `hook` when an elapsed cooldown moves the circuit to half-open.
    pub fn on_half_open(mut self, hook: impl Fn(&str) + Send + Sync + 'static) -> Self {
        self.callbacks.on_half_open = Some(hook_fn(hook));
        self
    }

    /// The circuit.
    #[must_use]
    pub fn build(self) -> CircuitBreaker {
        let core = Core::new(self.policy, self.scope);
        CircuitBreaker {
            shared: self.shared(),
            core,
        }
    }

    /// The circuit, for guarding futures.
    #[cfg(feature = "async")]
    #[must_use]
    pub fn build_async(self) -> crate::AsyncCircuitBreaker {
        crate::AsyncCircuitBreaker::from(self.build())
    }

    /// A circuit whose state lives in `storage`, shared by every process
    /// using it. An elected probe's lease lasts `probe_lease`.
    #[cfg(feature = "async")]
    #[must_use]
    pub fn build_distributed(
        self,
        storage: Arc<dyn crate::AsyncStorageBackend>,
        probe_lease: Duration,
    ) -> crate::DistributedCircuitBreaker {
        let policy = self.policy;
        crate::DistributedCircuitBreaker::from_parts(self.shared(), policy, storage, probe_lease)
    }

    fn shared(self) -> Shared {
        Shared {
            name: self.name,
            clock: self.clock.unwrap_or_else(|| Arc::new(SystemClock::new())),
            classifier: self.classifier,
            callbacks: self.callbacks,
        }
    }
}

fn hook_fn(hook: impl Fn(&str) + Send + Sync + 'static) -> CallbackFn {
    Arc::new(hook)
}
