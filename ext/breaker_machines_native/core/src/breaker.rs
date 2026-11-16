//! The circuit breaker decision core: admission, outcomes and transitions.
//!
//! Cooldown deadlines saturate at `Duration::MAX`; the saturation is not a
//! refusal.
//!
//! Every transition takes the next epoch, which fences the tickets issued
//! before it. Epochs never wrap: once `u64::MAX` is taken, every call that
//! would transition is [`Refusal::Exhausted`] with nothing changed, and the
//! calls that would not are still honoured.

use crate::{
    Abandoned, Admitted, Completed, Event, ForceClosed, Kind, Observed, Outcome, Policy, Refusal,
    Settlement, State, Ticket,
};
use core::time::Duration;
use periscope_machines::Issuer;

#[derive(Debug, Clone, Copy, PartialEq)]
enum Phase {
    Closed,
    Open {
        opened_at: Duration,
        retry_at: Duration,
    },
    HalfOpen {
        successes: u32,
        in_flight: u32,
    },
}

/// A circuit breaker that keeps its last `N` outcomes.
///
/// The caller supplies every instant (`now`, a [`Duration`] since an epoch
/// it picks) and every random draw; the breaker reads no clock. Outcomes
/// older than the policy's window stop counting; when more than `N` fall
/// inside it, the oldest are forgotten first.
///
/// A circuit that the cooldown would let probe stays [`State::Open`] until a
/// call ([`admit`](Self::admit) or [`observe`](Self::observe)) moves it.
#[derive(Debug, Clone, PartialEq)]
pub struct Breaker<const N: usize> {
    policy: Policy,
    issuer: Issuer,
    phase: Phase,
    /// Advances on every transition; a ticket from an older epoch still
    /// counts in the window but cannot drive a transition.
    epoch: u64,
    /// Tickets issued and not yet completed or abandoned.
    outstanding: u32,
    latest: Duration,
    events: [Event; N],
    start: usize,
    len: usize,
}

impl<const N: usize> Breaker<N> {
    const CAPACITY: () = assert!(N > 0, "a breaker keeps at least one outcome");

    /// A closed breaker issuing tickets in scope zero.
    #[must_use]
    pub const fn new(policy: Policy) -> Self {
        Self::with_scope(policy, 0)
    }

    /// A closed breaker issuing tickets in `scope`.
    #[must_use]
    pub const fn with_scope(policy: Policy, scope: u16) -> Self {
        let () = Self::CAPACITY;
        Self {
            policy,
            issuer: Issuer::new(scope),
            phase: Phase::Closed,
            epoch: 0,
            outstanding: 0,
            latest: Duration::ZERO,
            events: [Event {
                at: Duration::ZERO,
                outcome: Outcome::Success,
                took: Duration::ZERO,
            }; N],
            start: 0,
            len: 0,
        }
    }

    /// Admit one operation at `now`. A closed circuit admits a call; an open
    /// circuit whose cooldown has elapsed moves to half-open and admits its
    /// first probe; a half-open circuit admits a probe while a slot is free.
    ///
    /// # Errors
    ///
    /// [`Refusal::TimeRegression`] when `now` is before the latest honoured
    /// instant, [`Refusal::Open`] while the cooldown runs, [`Refusal::Busy`]
    /// when every probe slot is taken, [`Refusal::Full`] at the concurrency
    /// limit (or, without one, with `u32::MAX` tickets outstanding),
    /// [`Refusal::Exhausted`] when no ticket id is left, or when moving to
    /// half-open needs an epoch and none is left.
    pub fn admit(&mut self, now: Duration) -> Result<Admitted, Refusal> {
        self.check_time(now)?;
        let probe_limit = self.policy.recovery().half_open_calls().get();
        let half_opens = match self.phase {
            Phase::Open { retry_at, .. } if now < retry_at => return Err(Refusal::Open),
            Phase::HalfOpen { in_flight, .. } if in_flight >= probe_limit => {
                return Err(Refusal::Busy);
            }
            Phase::Open { .. } => true,
            Phase::Closed | Phase::HalfOpen { .. } => false,
        };
        // Without a limit the count itself is the last bound: a ticket past
        // `u32::MAX` outstanding could not be counted.
        if self.outstanding == u32::MAX
            || self
                .policy
                .max_concurrent()
                .is_some_and(|limit| self.outstanding >= limit.get())
        {
            return Err(Refusal::Full);
        }
        if half_opens {
            self.check_epochs(1)?;
        }
        let id = self.issuer.issue().map_err(|_| Refusal::Exhausted)?;
        self.latest = now;
        // Below `u32::MAX`, checked above.
        self.outstanding += 1;
        if half_opens {
            self.transition(Phase::HalfOpen {
                successes: 0,
                in_flight: 0,
            });
        }
        let kind = match &mut self.phase {
            Phase::HalfOpen { in_flight, .. } => {
                // Below the probe limit, checked above, or just reset to zero.
                *in_flight += 1;
                Kind::Probe
            }
            Phase::Closed | Phase::Open { .. } => Kind::Call,
        };
        let ticket = Ticket {
            id,
            epoch: self.epoch,
            admitted_at: now,
            kind,
            settled: None,
        };
        Ok(match (kind, half_opens) {
            (Kind::Call, _) => Admitted::Call(ticket),
            (Kind::Probe, false) => Admitted::Probe(ticket),
            (Kind::Probe, true) => Admitted::HalfOpened(ticket),
        })
    }

    /// Record the outcome of an admitted operation at `now`. A ticket
    /// admitted before the circuit last changed state still counts in the
    /// window but drives no transition. `draw` jitters the cooldown if the
    /// outcome opens the circuit. Completing a ticket again with the same
    /// outcome answers [`Completed::Duplicate`] and changes nothing.
    ///
    /// # Errors
    ///
    /// [`Refusal::Unknown`] for a ticket this breaker did not issue,
    /// [`Refusal::Mismatch`] for a ticket already abandoned or completed with
    /// the other outcome, [`Refusal::TimeRegression`] when `now` is before
    /// the latest honoured instant, [`Refusal::Exhausted`] when the outcome
    /// would transition and no epoch is left.
    pub fn complete(
        &mut self,
        ticket: &mut Ticket,
        outcome: Outcome,
        now: Duration,
        draw: u64,
    ) -> Result<Completed, Refusal> {
        self.check_owner(ticket)?;
        match ticket.settled {
            None => {}
            Some(Settlement::Completed(original, answer)) if original == outcome => {
                return Ok(Completed::Duplicate(answer));
            }
            Some(Settlement::Completed(..) | Settlement::Abandoned) => {
                return Err(Refusal::Mismatch);
            }
        }
        self.check_time(now)?;
        let (outstanding, phase) = self.released(ticket)?;
        let event = Event {
            at: now,
            outcome,
            took: now.saturating_sub(ticket.admitted_at),
        };
        let verdict = self.verdict(phase, &event, ticket.epoch == self.epoch);
        self.check_epochs(verdict.transitions())?;
        self.outstanding = outstanding;
        self.phase = phase;
        self.latest = now;
        let settled = self.settle(event, verdict, draw);
        ticket.settled = Some(Settlement::Completed(outcome, settled));
        Ok(Completed::Settled(settled))
    }

    /// Give back an admission without recording an outcome, for an operation
    /// that must not count (cancelled, or a failure the caller classifies as
    /// harmless). Frees its concurrency slot and probe slot.
    ///
    /// Abandoning a ticket again answers [`Abandoned::Duplicate`].
    ///
    /// # Errors
    ///
    /// [`Refusal::Unknown`] for a ticket this breaker did not issue,
    /// [`Refusal::Mismatch`] for a ticket already completed.
    pub fn abandon(&mut self, ticket: &mut Ticket) -> Result<Abandoned, Refusal> {
        self.check_owner(ticket)?;
        match ticket.settled {
            None => {}
            Some(Settlement::Abandoned) => return Ok(Abandoned::Duplicate),
            Some(Settlement::Completed(..)) => return Err(Refusal::Mismatch),
        }
        (self.outstanding, self.phase) = self.released(ticket)?;
        ticket.settled = Some(Settlement::Abandoned);
        Ok(Abandoned::Released)
    }

    /// Record an operation that ran outside this breaker's admission, for a
    /// circuit that watches work instead of gating it. An open circuit whose
    /// cooldown has elapsed moves to half-open first; while the cooldown
    /// runs the outcome is recorded but drives no transition.
    ///
    /// # Errors
    ///
    /// [`Refusal::TimeRegression`] when `now` is before the latest honoured
    /// instant, [`Refusal::Exhausted`] when the call would transition and
    /// too few epochs are left.
    pub fn observe(
        &mut self,
        outcome: Outcome,
        took: Duration,
        now: Duration,
        draw: u64,
    ) -> Result<Observed, Refusal> {
        self.check_time(now)?;
        let event = Event {
            at: now,
            outcome,
            took,
        };
        let (half_opens, verdict) = match self.phase {
            Phase::Open { retry_at, .. } if now >= retry_at => {
                let probing = Phase::HalfOpen {
                    successes: 0,
                    in_flight: 0,
                };
                (true, self.verdict(probing, &event, true))
            }
            Phase::Open { .. } => (false, self.verdict(self.phase, &event, false)),
            Phase::Closed | Phase::HalfOpen { .. } => {
                (false, self.verdict(self.phase, &event, true))
            }
        };
        self.check_epochs(u64::from(half_opens) + verdict.transitions())?;
        self.latest = now;
        if half_opens {
            self.transition(Phase::HalfOpen {
                successes: 0,
                in_flight: 0,
            });
            return Ok(Observed::HalfOpened(self.settle(event, verdict, draw)));
        }
        Ok(Observed::Settled(self.settle(event, verdict, draw)))
    }

    /// Open the circuit at `now` whatever its threshold says, restarting the
    /// cooldown (drawn with `draw`) if it was already open.
    ///
    /// # Errors
    ///
    /// [`Refusal::TimeRegression`] when `now` is before the latest honoured
    /// instant, [`Refusal::Exhausted`] when no epoch is left.
    pub fn force_open(&mut self, now: Duration, draw: u64) -> Result<(), Refusal> {
        self.check_time(now)?;
        self.check_epochs(1)?;
        self.latest = now;
        self.open(now, draw);
        Ok(())
    }

    /// Close the circuit whatever its threshold says, keeping the outcomes
    /// in its window; [`reset`](Self::reset) clears them too.
    ///
    /// # Errors
    ///
    /// [`Refusal::Exhausted`] when the circuit is not closed and no epoch is
    /// left.
    pub fn force_close(&mut self) -> Result<ForceClosed, Refusal> {
        match self.phase {
            Phase::Closed => Ok(ForceClosed::AlreadyClosed),
            Phase::Open { .. } | Phase::HalfOpen { .. } => {
                self.check_epochs(1)?;
                self.transition(Phase::Closed);
                Ok(ForceClosed::Closed)
            }
        }
    }

    /// Close the circuit and clear its window. Tickets outstanding keep
    /// their concurrency slots but can no longer drive a transition.
    ///
    /// # Errors
    ///
    /// [`Refusal::Exhausted`] when no epoch is left.
    pub fn reset(&mut self) -> Result<(), Refusal> {
        self.check_epochs(1)?;
        self.start = 0;
        self.len = 0;
        self.transition(Phase::Closed);
        Ok(())
    }

    /// The circuit's state.
    #[must_use]
    pub const fn state(&self) -> State {
        match self.phase {
            Phase::Closed => State::Closed,
            Phase::Open { .. } => State::Open,
            Phase::HalfOpen { .. } => State::HalfOpen,
        }
    }

    /// The policy this breaker decides by.
    #[must_use]
    pub const fn policy(&self) -> Policy {
        self.policy
    }

    /// The latest honoured instant.
    #[must_use]
    pub const fn latest(&self) -> Duration {
        self.latest
    }

    /// The instant the circuit opened, while it is open.
    #[must_use]
    pub const fn opened_at(&self) -> Option<Duration> {
        match self.phase {
            Phase::Open { opened_at, .. } => Some(opened_at),
            Phase::Closed | Phase::HalfOpen { .. } => None,
        }
    }

    /// The instant from which a probe may run, while the circuit is open.
    #[must_use]
    pub const fn retry_at(&self) -> Option<Duration> {
        match self.phase {
            Phase::Open { retry_at, .. } => Some(retry_at),
            Phase::Closed | Phase::HalfOpen { .. } => None,
        }
    }

    /// How long after `now` a probe may run, while the circuit is open;
    /// zero once the cooldown has elapsed.
    #[must_use]
    pub const fn retry_after(&self, now: Duration) -> Option<Duration> {
        match self.phase {
            Phase::Open { retry_at, .. } => Some(retry_at.saturating_sub(now)),
            Phase::Closed | Phase::HalfOpen { .. } => None,
        }
    }

    /// Failures in the window ending at `now`.
    #[must_use]
    pub fn failures(&self, now: Duration) -> u32 {
        self.count(Outcome::Failure, now)
    }

    /// Successes in the window ending at `now`.
    #[must_use]
    pub fn successes(&self, now: Duration) -> u32 {
        self.count(Outcome::Success, now)
    }

    /// Probe slots taken in the current half-open visit: probes that
    /// succeeded plus probes still running. Zero in every other state.
    #[must_use]
    pub const fn half_open_attempts(&self) -> u32 {
        match self.phase {
            Phase::HalfOpen {
                successes,
                in_flight,
            } => successes.saturating_add(in_flight),
            Phase::Closed | Phase::Open { .. } => 0,
        }
    }

    /// Probes that succeeded in the current half-open visit. Zero in every
    /// other state.
    #[must_use]
    pub const fn half_open_successes(&self) -> u32 {
        match self.phase {
            Phase::HalfOpen { successes, .. } => successes,
            Phase::Closed | Phase::Open { .. } => 0,
        }
    }

    /// Tickets issued and not yet completed or abandoned.
    #[must_use]
    pub const fn outstanding(&self) -> u32 {
        self.outstanding
    }

    /// The scope this breaker issues tickets in.
    #[must_use]
    pub const fn scope(&self) -> u16 {
        self.issuer.scope()
    }

    /// Copy the newest `out.len()` outcomes kept, oldest first, into `out`
    /// and report how many were written; the rest of `out` is untouched.
    pub fn events(&self, out: &mut [Event]) -> usize {
        let n = out.len().min(self.len);
        // `n <= len`.
        let skip = self.len - n;
        for (slot, event) in out.iter_mut().zip(self.kept().skip(skip)) {
            *slot = *event;
        }
        n
    }

    fn check_time(&self, now: Duration) -> Result<(), Refusal> {
        if now < self.latest {
            return Err(Refusal::TimeRegression);
        }
        Ok(())
    }

    /// A ticket must be of this scope and sequence.
    const fn check_owner(&self, ticket: &Ticket) -> Result<(), Refusal> {
        if !self.issuer.owns(ticket.id) {
            return Err(Refusal::Unknown);
        }
        Ok(())
    }

    /// Keep `event`, letting the oldest go when the ring is full.
    ///
    /// `start < N` and `len <= N` always, and `N > 0` (`CAPACITY`): the
    /// sums cannot overflow and the remainders are in bounds.
    fn push(&mut self, event: Event) {
        // The entry after the newest kept, which for a full ring is the
        // oldest, at `start`.
        let next = (self.start + self.len) % N;
        let Some(entry) = self.events.get_mut(next) else {
            debug_assert!(false, "a remainder of N is below N");
            return;
        };
        *entry = event;
        if self.len < N {
            self.len += 1;
        } else {
            self.start = (self.start + 1) % N;
        }
    }

    /// The outcomes kept, oldest first.
    fn kept(&self) -> impl Iterator<Item = &Event> {
        self.events.iter().cycle().skip(self.start).take(self.len)
    }

    fn count(&self, outcome: Outcome, now: Duration) -> u32 {
        self.tally(self.kept(), outcome, now)
    }

    /// `outcome`s among `events` in the window ending at `now`.
    fn tally<'a>(
        &self,
        events: impl Iterator<Item = &'a Event>,
        outcome: Outcome,
        now: Duration,
    ) -> u32 {
        let since = now.saturating_sub(self.policy.window());
        let count = events
            .filter(|event| event.outcome == outcome && event.at >= since && event.at <= now)
            .count();
        u32::try_from(count).unwrap_or(u32::MAX)
    }
}

mod settle;
mod share;

#[cfg(test)]
pub mod tests;
