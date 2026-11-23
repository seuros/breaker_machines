//! The std runtime: a named circuit that guards closures and reads a clock.

use crate::callbacks::{Callbacks, Transition};
use crate::clock::{Clock, Draws};
use crate::lifecycle::{DynamicLifecycle, LifecycleEvent, settled_event, state_of};
use crate::{
    Abandoned, Admitted, Breaker, CircuitError, Completed, Event, FailureClassifier,
    FailureContext, FallbackContext, ForceClosed, Observed, Outcome, Policy, Refusal, Settled,
    State, Ticket,
};
use core::convert::Infallible;
use core::time::Duration;
use std::boxed::Box;
use std::sync::Arc;
use std::vec::Vec;

/// Outcomes a runtime circuit keeps in its window.
pub const WINDOW: usize = 1000;

/// What every runtime flavour reads outside its decision state.
#[derive(Clone)]
pub struct Shared {
    pub name: Arc<str>,
    pub clock: Arc<dyn Clock>,
    pub classifier: Option<Arc<dyn FailureClassifier>>,
    pub callbacks: Callbacks,
}

impl Shared {
    /// The outcome a result counts as, or `None` when the classifier says
    /// the failure must not count.
    pub fn classify<T, E: 'static>(
        &self,
        result: &Result<T, E>,
        took: Duration,
    ) -> Option<Outcome> {
        match result {
            Ok(_) => Some(Outcome::Success),
            Err(error) => self
                .classifier
                .as_ref()
                .is_none_or(|classifier| {
                    classifier.should_trip(&FailureContext {
                        circuit_name: &self.name,
                        error,
                        took,
                    })
                })
                .then_some(Outcome::Failure),
        }
    }

    pub fn notify(&self, transitions: impl IntoIterator<Item = Transition>) {
        for transition in transitions {
            self.callbacks.fire(transition, &self.name);
        }
    }

    pub fn refused<E>(&self, refusal: Refusal) -> CircuitError<E> {
        CircuitError::Refused {
            circuit: Arc::clone(&self.name),
            refusal,
        }
    }

    pub fn fallback_context(
        &self,
        refusal: Refusal,
        retry_after: Option<Duration>,
    ) -> FallbackContext {
        FallbackContext {
            circuit: Arc::clone(&self.name),
            refusal,
            retry_after,
        }
    }
}

impl core::fmt::Debug for Shared {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Shared")
            .field("name", &self.name)
            .field("clock", &self.clock)
            .field("classifier", &self.classifier)
            .field("callbacks", &self.callbacks)
            .finish()
    }
}

/// The decision state: the breaker, the lifecycle machine replaying its
/// transitions, and the draws that jitter it.
#[derive(Debug)]
pub struct Core {
    pub breaker: Box<Breaker<WINDOW>>,
    lifecycle: DynamicLifecycle<()>,
    draws: Draws,
}

impl Core {
    fn new(policy: Policy, scope: u16) -> Self {
        Self {
            breaker: Box::new(Breaker::with_scope(policy, scope)),
            lifecycle: DynamicLifecycle::new(()),
            draws: Draws::new(),
        }
    }

    /// The clock's reading, never behind the latest honoured instant: a
    /// clock that steps back reads as standing still.
    pub fn now(&self, clock: &dyn Clock) -> Duration {
        self.clamp_time(clock.now())
    }

    pub fn clamp_time(&self, sampled_at: Duration) -> Duration {
        sampled_at.max(self.breaker.latest())
    }

    /// The lifecycle machine's state.
    pub fn lifecycle(&self) -> State {
        state_of(self.lifecycle.current_state())
    }

    /// Replay a transition the core answered on the lifecycle machine and
    /// name the hook it fires. The machine has no guards, so a transition
    /// the core made is always one it accepts.
    fn replay(&mut self, event: LifecycleEvent) -> Option<Transition> {
        let transition = match event {
            LifecycleEvent::Trip | LifecycleEvent::Reopen | LifecycleEvent::ForceOpen => {
                Some(Transition::Opened)
            }
            LifecycleEvent::Close | LifecycleEvent::ForceClose => Some(Transition::Closed),
            LifecycleEvent::AttemptRecovery => Some(Transition::HalfOpened),
            LifecycleEvent::Reset => None,
        };
        let replayed = self.lifecycle.handle(event);
        debug_assert!(
            replayed.is_ok(),
            "the machine refused a core transition: {replayed:?}"
        );
        transition
    }

    fn replay_settled(&mut self, before: State, settled: Settled) -> Option<Transition> {
        settled_event(before, settled).and_then(|event| self.replay(event))
    }

    pub fn admit(&mut self, now: Duration) -> Result<(Ticket, Option<Transition>), Refusal> {
        Ok(match self.breaker.admit(now)? {
            Admitted::Call(ticket) | Admitted::Probe(ticket) => (ticket, None),
            Admitted::HalfOpened(ticket) => (ticket, self.replay(LifecycleEvent::AttemptRecovery)),
        })
    }

    /// Complete `ticket` with `outcome`, or abandon it when `None`.
    pub fn settle(
        &mut self,
        ticket: &mut Ticket,
        outcome: Option<Outcome>,
        now: Duration,
    ) -> Result<Option<Transition>, Refusal> {
        let Some(outcome) = outcome else {
            return match self.breaker.abandon(ticket)? {
                Abandoned::Released | Abandoned::Duplicate => Ok(None),
            };
        };
        let draw = self.draws.next();
        let before = self.breaker.state();
        Ok(match self.breaker.complete(ticket, outcome, now, draw)? {
            Completed::Settled(settled) => self.replay_settled(before, settled),
            Completed::Duplicate(_) => None,
        })
    }

    pub fn observe(
        &mut self,
        outcome: Option<Outcome>,
        took: Duration,
        now: Duration,
    ) -> [Option<Transition>; 2] {
        let Some(outcome) = outcome else {
            return [None, None];
        };
        let draw = self.draws.next();
        let before = self.breaker.state();
        match self.breaker.observe(outcome, took, now, draw) {
            Ok(Observed::Settled(settled)) => [self.replay_settled(before, settled), None],
            Ok(Observed::HalfOpened(settled)) => {
                // The core already settled; the machine catches up in order.
                let half_opened = self.replay(LifecycleEvent::AttemptRecovery);
                [half_opened, self.replay_settled(State::HalfOpen, settled)]
            }
            // `now` is clamped to the latest honoured instant, so a regressed
            // instant is never refused. With no epoch left the outcome is not
            // recorded and nothing transitions: the circuit's state, which
            // the caller reads next, is the whole answer.
            Err(Refusal::TimeRegression | Refusal::Exhausted) => [None, None],
            Err(
                Refusal::Open
                | Refusal::Busy
                | Refusal::Full
                | Refusal::Unknown
                | Refusal::Mismatch,
            ) => {
                debug_assert!(
                    false,
                    "observe refuses only a regressed instant or no epoch"
                );
                [None, None]
            }
        }
    }

    pub fn force_open(&mut self, now: Duration) -> Result<Option<Transition>, Refusal> {
        let draw = self.draws.next();
        self.breaker.force_open(now, draw)?;
        Ok(self.replay(LifecycleEvent::ForceOpen))
    }

    pub fn force_close(&mut self) -> Result<Option<Transition>, Refusal> {
        Ok(match self.breaker.force_close()? {
            ForceClosed::Closed => self.replay(LifecycleEvent::ForceClose),
            ForceClosed::AlreadyClosed => None,
        })
    }

    pub fn reset(&mut self) -> Result<(), Refusal> {
        self.breaker.reset()?;
        // Reset fires no hook.
        let hook = self.replay(LifecycleEvent::Reset);
        debug_assert_eq!(hook, None);
        Ok(())
    }

    pub fn events(&self, limit: usize) -> Vec<Event> {
        let mut out = std::vec![Event::default(); limit.min(WINDOW)];
        let n = self.breaker.events(&mut out);
        out.truncate(n);
        out
    }
}

/// Abandons the ticket on drop unless it was settled, so an operation that
/// panics frees its slots instead of wedging a half-open circuit.
struct Pending<'a> {
    core: &'a mut Core,
    ticket: Ticket,
}

impl Drop for Pending<'_> {
    fn drop(&mut self) {
        if self.ticket.settled().is_none() {
            // The circuit issued this ticket and it is unsettled, so the
            // abandon is honoured; nothing is left to report from a drop.
            let abandoned = self.core.breaker.abandon(&mut self.ticket);
            debug_assert!(
                abandoned.is_ok(),
                "an unsettled ticket abandons: {abandoned:?}"
            );
        }
    }
}

/// Record `result` against `ticket` and hand it back.
pub fn finish<T, E: 'static>(
    shared: &Shared,
    core: &mut Core,
    ticket: &mut Ticket,
    result: Result<T, E>,
) -> Result<T, CircuitError<E>> {
    let now = core.now(&*shared.clock);
    let took = now.saturating_sub(ticket.admitted_at());
    let outcome = shared.classify(&result, took);
    let transition = core
        .settle(ticket, outcome, now)
        .map_err(|refusal| shared.refused(refusal))?;
    shared.notify(transition);
    result.map_err(CircuitError::Execution)
}

/// A named circuit breaker that guards closures, reading a [`Clock`] and
/// firing [`Callbacks`] on its transitions.
#[derive(Debug)]
pub struct CircuitBreaker {
    shared: Shared,
    core: Core,
}

impl CircuitBreaker {
    /// A circuit named `name` deciding by `policy`, on the system clock.
    #[must_use]
    pub fn new(name: impl Into<Arc<str>>, policy: Policy) -> Self {
        Self::builder(name, policy).build()
    }

    /// A builder for a circuit named `name` deciding by `policy`.
    pub fn builder(name: impl Into<Arc<str>>, policy: Policy) -> CircuitBuilder {
        CircuitBuilder::new(name, policy)
    }

    /// The circuit's name.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.shared.name
    }

    /// Run `operation` if the circuit admits it and record its outcome.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] when the circuit refuses the call,
    /// [`CircuitError::Execution`] with the operation's own error.
    pub fn call<T, E: 'static>(
        &mut self,
        operation: impl FnOnce() -> Result<T, E>,
    ) -> Result<T, CircuitError<E>> {
        self.call_with_fallback(operation, |context| {
            Err(CircuitError::Refused {
                circuit: Arc::clone(&context.circuit),
                refusal: context.refusal,
            })
        })
    }

    /// Run `operation` if the circuit admits it, `fallback` if it refuses.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Execution`] with the operation's own error; whatever
    /// `fallback` answers when the call is refused.
    pub fn call_with_fallback<T, E: 'static>(
        &mut self,
        operation: impl FnOnce() -> Result<T, E>,
        fallback: impl FnOnce(&FallbackContext) -> Result<T, CircuitError<E>>,
    ) -> Result<T, CircuitError<E>> {
        let now = self.core.now(&*self.shared.clock);
        let (ticket, transition) = match self.core.admit(now) {
            Ok(admitted) => admitted,
            Err(refusal) => {
                let retry_after = self.core.breaker.retry_after(now);
                return fallback(&self.shared.fallback_context(refusal, retry_after));
            }
        };
        self.shared.notify(transition);
        let mut pending = Pending {
            core: &mut self.core,
            ticket,
        };
        let result = operation();
        finish(&self.shared, pending.core, &mut pending.ticket, result)
    }

    /// Admit one operation without running it, for a caller that cannot
    /// keep the circuit borrowed while it runs. Settle the ticket with
    /// [`complete`](Self::complete) or [`abandon`](Self::abandon).
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] when the circuit refuses the call.
    pub fn admit(&mut self) -> Result<Ticket, CircuitError<Infallible>> {
        let now = self.core.now(&*self.shared.clock);
        let (ticket, transition) = self
            .core
            .admit(now)
            .map_err(|refusal| self.shared.refused(refusal))?;
        self.shared.notify(transition);
        Ok(ticket)
    }

    /// Record the result of an operation admitted by [`admit`](Self::admit)
    /// and hand it back. The failure classifier applies.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Execution`] with the operation's own error;
    /// [`CircuitError::Refused`] for a ticket this circuit did not issue or
    /// that was already settled the other way (the result is dropped).
    pub fn complete<T, E: 'static>(
        &mut self,
        ticket: &mut Ticket,
        result: Result<T, E>,
    ) -> Result<T, CircuitError<E>> {
        finish(&self.shared, &mut self.core, ticket, result)
    }

    /// Give back an admission without recording an outcome.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] for a ticket this circuit did not issue or
    /// that was already completed.
    pub fn abandon(&mut self, ticket: &mut Ticket) -> Result<(), CircuitError<Infallible>> {
        let now = self.core.now(&*self.shared.clock);
        self.core
            .settle(ticket, None, now)
            .map(drop)
            .map_err(|refusal| self.shared.refused(refusal))
    }

    /// Record an operation that ran outside this circuit's admission and
    /// answer the state it left the circuit in. See [`Breaker::observe`].
    pub fn observe<E: 'static>(&mut self, outcome: &Result<(), E>, took: Duration) -> State {
        let outcome = self.shared.classify(outcome, took);
        let now = self.core.now(&*self.shared.clock);
        let transitions = self.core.observe(outcome, took, now);
        self.shared.notify(transitions.into_iter().flatten());
        self.state()
    }

    /// Open the circuit whatever its threshold says, restarting the
    /// cooldown.
    ///
    /// # Errors
    ///
    /// [`CircuitError::Refused`] with [`Refusal::Exhausted`] when no
    /// transition epoch is left; nothing changed.
    pub fn force_open(&mut self) -> Result<(), CircuitError<Infallible>> {
        let now = self.core.now(&*self.shared.clock);
        let transition = self
            .core
            .force_open(now)
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
    pub fn force_close(&mut self) -> Result<(), CircuitError<Infallible>> {
        let transition = self
            .core
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
    pub fn reset(&mut self) -> Result<(), CircuitError<Infallible>> {
        self.core
            .reset()
            .map_err(|refusal| self.shared.refused(refusal))
    }

    /// The circuit's state, as its lifecycle machine holds it (always the
    /// core's).
    #[must_use]
    pub fn state(&self) -> State {
        self.core.lifecycle()
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

    /// The circuit's clock reading, the time base of every instant it
    /// reports.
    #[must_use]
    pub fn now(&self) -> Duration {
        self.core.now(&*self.shared.clock)
    }

    /// Failures in the window ending now.
    #[must_use]
    pub fn failures(&self) -> u32 {
        self.core.breaker.failures(self.now())
    }

    /// Successes in the window ending now.
    #[must_use]
    pub fn successes(&self) -> u32 {
        self.core.breaker.successes(self.now())
    }

    /// The instant the circuit opened, while it is open.
    #[must_use]
    pub fn opened_at(&self) -> Option<Duration> {
        self.core.breaker.opened_at()
    }

    /// How long until a probe may run, while the circuit is open.
    #[must_use]
    pub fn retry_after(&self) -> Option<Duration> {
        self.core.breaker.retry_after(self.now())
    }

    /// The newest `limit` outcomes kept, oldest first.
    #[must_use]
    pub fn events(&self, limit: usize) -> Vec<Event> {
        self.core.events(limit)
    }

    /// The decision core, for every other query.
    #[must_use]
    pub fn breaker(&self) -> &Breaker<WINDOW> {
        &self.core.breaker
    }

    #[cfg(feature = "async")]
    #[must_use]
    pub(crate) fn into_parts(self) -> (Shared, Core) {
        (self.shared, self.core)
    }
}

mod builder;

pub use builder::CircuitBuilder;

#[cfg(test)]
mod tests;
