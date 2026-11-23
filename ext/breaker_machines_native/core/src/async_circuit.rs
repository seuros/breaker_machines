//! A runtime circuit for futures: decisions under a short lock, operations
//! awaited outside it.

use crate::circuit::{Core, Shared, WINDOW};
use crate::{
    Breaker, CircuitBreaker, CircuitBuilder, CircuitError, FallbackContext, Policy, State, Ticket,
};
use core::convert::Infallible;
use core::future::Future;
use core::time::Duration;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

/// A circuit breaker that guards futures. Share it across tasks with `Arc`;
/// its lock is never held across an `.await` or while a hook, classifier or
/// fallback runs.
#[derive(Debug)]
pub struct AsyncCircuitBreaker {
    shared: Shared,
    core: Mutex<Core>,
}

impl From<CircuitBreaker> for AsyncCircuitBreaker {
    fn from(circuit: CircuitBreaker) -> Self {
        let (shared, core) = circuit.into_parts();
        Self {
            shared,
            core: Mutex::new(core),
        }
    }
}

impl AsyncCircuitBreaker {
    /// A circuit named `name` deciding by `policy`, on the system clock.
    #[must_use]
    pub fn new(name: impl Into<Arc<str>>, policy: Policy) -> Self {
        CircuitBreaker::new(name, policy).into()
    }

    /// A builder; finish it with [`CircuitBuilder::build_async`].
    pub fn builder(name: impl Into<Arc<str>>, policy: Policy) -> CircuitBuilder {
        CircuitBreaker::builder(name, policy)
    }

    /// The circuit's name.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.shared.name
    }

    /// Await `operation` if the circuit admits it and record its outcome.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] when the circuit refuses the call,
    /// [`CircuitError::Execution`] with the operation's own error.
    pub async fn call<F, Fut, T, E: 'static>(&self, operation: F) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        self.call_with_fallback(operation, |context| async move {
            Err(CircuitError::Refused {
                circuit: context.circuit,
                refusal: context.refusal,
            })
        })
        .await
    }

    /// Await `operation` if the circuit admits it, `fallback` if it refuses.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Execution`] with the operation's own error; whatever
    /// `fallback` answers when the call is refused.
    pub async fn call_with_fallback<F, Fut, G, FutG, T, E: 'static>(
        &self,
        operation: F,
        fallback: G,
    ) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
        G: FnOnce(FallbackContext) -> FutG,
        FutG: Future<Output = Result<T, CircuitError<E>>>,
    {
        let ticket = match self.admit_inner() {
            Ok(ticket) => ticket,
            Err(context) => return fallback(context).await,
        };
        ticket.complete(operation().await)
    }

    /// Admit one operation without running it, for work whose outcome is
    /// only known after an `.await` this circuit cannot wrap. Dropping the
    /// ticket unsettled (a cancelled future, an early return) abandons it.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] when the circuit refuses the call.
    pub fn admit(&self) -> Result<AsyncTicket<'_>, CircuitError<Infallible>> {
        self.admit_inner().map_err(|context| CircuitError::Refused {
            circuit: context.circuit,
            refusal: context.refusal,
        })
    }

    /// Record an operation that ran outside this circuit's admission and
    /// answer the state it left the circuit in.
    pub fn observe<E: 'static>(&self, outcome: &Result<(), E>, took: Duration) -> State {
        let outcome = self.shared.classify(outcome, took);
        let sampled_at = self.shared.clock.now();
        let (transitions, state) = {
            let mut core = self.lock();
            let now = core.clamp_time(sampled_at);
            (core.observe(outcome, took, now), core.lifecycle())
        };
        self.shared.notify(transitions.into_iter().flatten());
        state
    }

    /// Open the circuit whatever its threshold says, restarting the
    /// cooldown.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] with [`Refusal::Exhausted`] when no
    /// transition epoch is left; nothing changed.
    pub fn force_open(&self) -> Result<(), CircuitError<Infallible>> {
        let sampled_at = self.shared.clock.now();
        let transition = {
            let mut core = self.lock();
            let now = core.clamp_time(sampled_at);
            core.force_open(now)
        }
        .map_err(|refusal| self.shared.refused(refusal))?;
        self.shared.notify(transition);
        Ok(())
    }

    /// Close the circuit whatever its threshold says, keeping its window.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] with [`Refusal::Exhausted`] when the
    /// circuit is not closed and no transition epoch is left; nothing
    /// changed.
    pub fn force_close(&self) -> Result<(), CircuitError<Infallible>> {
        let transition = self
            .lock()
            .force_close()
            .map_err(|refusal| self.shared.refused(refusal))?;
        self.shared.notify(transition);
        Ok(())
    }

    /// Close the circuit and clear its window; fires no hook.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] with [`Refusal::Exhausted`] when no
    /// transition epoch is left; nothing changed.
    pub fn reset(&self) -> Result<(), CircuitError<Infallible>> {
        self.lock()
            .reset()
            .map_err(|refusal| self.shared.refused(refusal))
    }

    /// The circuit's state.
    #[must_use]
    pub fn state(&self) -> State {
        self.lock().lifecycle()
    }

    /// Whether the circuit is open.
    #[must_use]
    pub fn is_open(&self) -> bool {
        self.state() == State::Open
    }

    /// Whether the circuit is closed.
    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.state() == State::Closed
    }

    /// The instant the circuit opened, while it is open.
    #[must_use]
    pub fn opened_at(&self) -> Option<Duration> {
        self.lock().breaker.opened_at()
    }

    /// How long until a probe may run, while the circuit is open.
    #[must_use]
    pub fn retry_after(&self) -> Option<Duration> {
        let sampled_at = self.shared.clock.now();
        let core = self.lock();
        core.breaker.retry_after(core.clamp_time(sampled_at))
    }

    /// A copy of the decision core, for every other query.
    #[must_use]
    pub fn breaker(&self) -> Breaker<WINDOW> {
        (*self.lock().breaker).clone()
    }

    fn admit_inner(&self) -> Result<AsyncTicket<'_>, FallbackContext> {
        let sampled_at = self.shared.clock.now();
        let admitted = {
            let mut core = self.lock();
            let now = core.clamp_time(sampled_at);
            core.admit(now)
                .map_err(|refusal| (refusal, core.breaker.retry_after(now)))
        };
        match admitted {
            Ok((ticket, transition)) => {
                self.shared.notify(transition);
                Ok(AsyncTicket {
                    circuit: self,
                    ticket,
                })
            }
            Err((refusal, retry_after)) => Err(self.shared.fallback_context(refusal, retry_after)),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Core> {
        // Sample the configurable clock before locking, then clamp against the
        // latest instant while holding the guard.
        self.core.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Admission for one operation that runs across `.await`, from
/// [`AsyncCircuitBreaker::admit`]. Settle it with
/// [`complete`](Self::complete) or [`abandon`](Self::abandon); dropping it
/// unsettled abandons it.
#[must_use = "pass the ticket to `complete` or `abandon`; dropping it records no outcome"]
#[derive(Debug)]
pub struct AsyncTicket<'a> {
    circuit: &'a AsyncCircuitBreaker,
    ticket: Ticket,
}

impl AsyncTicket<'_> {
    /// Record the operation's result and hand it back; the failure
    /// classifier applies.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Execution`] with the operation's own error.
    pub fn complete<T, E: 'static>(mut self, result: Result<T, E>) -> Result<T, CircuitError<E>> {
        let circuit = self.circuit;
        let shared = &circuit.shared;
        let took = shared.clock.now().saturating_sub(self.ticket.admitted_at());
        // The classifier is user code: it runs before the lock is taken.
        let outcome = shared.classify(&result, took);
        let sampled_at = shared.clock.now();
        let settled = {
            let mut core = circuit.lock();
            let now = core.clamp_time(sampled_at);
            core.settle(&mut self.ticket, outcome, now)
        };
        match settled {
            Ok(transition) => {
                shared.notify(transition);
                result.map_err(CircuitError::Execution)
            }
            Err(refusal) => Err(shared.refused(refusal)),
        }
    }

    /// Give back the admission without recording an outcome.
    pub fn abandon(self) {
        drop(self);
    }

    /// The instant the ticket was admitted at.
    #[must_use]
    pub const fn admitted_at(&self) -> Duration {
        self.ticket.admitted_at()
    }
}

impl Drop for AsyncTicket<'_> {
    fn drop(&mut self) {
        if self.ticket.settled().is_none() {
            // The circuit issued this ticket and it is unsettled, so the
            // abandon is honoured; nothing is left to report from a drop.
            let sampled_at = self.circuit.shared.clock.now();
            let abandoned = {
                let mut core = self.circuit.lock();
                let now = core.clamp_time(sampled_at);
                core.settle(&mut self.ticket, None, now)
            };
            debug_assert!(
                abandoned.is_ok(),
                "an unsettled ticket abandons: {abandoned:?}"
            );
        }
    }
}

#[cfg(test)]
mod tests;
