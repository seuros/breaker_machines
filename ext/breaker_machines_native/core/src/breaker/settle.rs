//! Recording outcomes and taking transitions: what a call will do is
//! decided first, so a refusal (no epoch left) changes nothing.

use super::{Breaker, Phase};
use crate::{Event, Kind, Outcome, Refusal, Settled, Ticket};
use core::time::Duration;

/// What recording an outcome will do, decided before anything changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Verdict {
    /// Recorded; the phase is unchanged.
    Counted,
    /// A half-open probe success below the threshold: the count it leaves.
    Probed(u32),
    /// The success that closes a half-open circuit.
    Close,
    /// The failure that opens the circuit.
    Open,
}

impl Verdict {
    /// The transitions (and so the epochs) it takes.
    pub(super) const fn transitions(self) -> u64 {
        match self {
            Self::Counted | Self::Probed(_) => 0,
            Self::Close | Self::Open => 1,
        }
    }
}

impl<const N: usize> Breaker<N> {
    /// What freeing a live ticket leaves: the outstanding count and the
    /// phase. Something must be outstanding for it to free: a ticket of
    /// another breaker in the same scope can pass the issuer check, so a
    /// count it would drive below zero is [`Refusal::Unknown`].
    pub(super) fn released(&self, ticket: &Ticket) -> Result<(u32, Phase), Refusal> {
        let outstanding = self.outstanding.checked_sub(1).ok_or(Refusal::Unknown)?;
        let phase = match self.phase {
            Phase::HalfOpen {
                successes,
                in_flight,
            } if ticket.kind == Kind::Probe && ticket.epoch == self.epoch => Phase::HalfOpen {
                successes,
                in_flight: in_flight.checked_sub(1).ok_or(Refusal::Unknown)?,
            },
            phase => phase,
        };
        Ok((outstanding, phase))
    }

    /// What recording `event` in `phase` will do. Judged on the window as
    /// it will be once `event` is kept.
    pub(super) fn verdict(&self, phase: Phase, event: &Event, may_transition: bool) -> Verdict {
        if !may_transition {
            return Verdict::Counted;
        }
        match (phase, event.outcome) {
            (Phase::HalfOpen { successes, .. }, Outcome::Success) => {
                let successes = successes.saturating_add(1);
                if successes < self.policy.recovery().success_threshold().get() {
                    Verdict::Probed(successes)
                } else {
                    Verdict::Close
                }
            }
            (Phase::HalfOpen { .. }, Outcome::Failure) => Verdict::Open,
            (Phase::Closed, Outcome::Failure) if self.crosses(event) => Verdict::Open,
            (Phase::Closed | Phase::Open { .. }, _) => Verdict::Counted,
        }
    }

    /// Whether the threshold is exceeded once `event` is kept: the oldest
    /// outcome goes when the ring is full.
    fn crosses(&self, event: &Event) -> bool {
        let evicted = usize::from(self.len == N);
        let kept = || self.kept().skip(evicted).chain(core::iter::once(event));
        self.policy.threshold().exceeded(
            self.tally(kept(), Outcome::Failure, event.at),
            self.tally(kept(), Outcome::Success, event.at),
        )
    }

    /// Keep `event` and do what `verdict` decided. The epochs it takes were
    /// checked first.
    pub(super) fn settle(&mut self, event: Event, verdict: Verdict, draw: u64) -> Settled {
        self.push(event);
        match verdict {
            Verdict::Counted => Settled::Counted,
            Verdict::Probed(count) => {
                if let Phase::HalfOpen { successes, .. } = &mut self.phase {
                    *successes = count;
                } else {
                    debug_assert!(false, "a probe verdict is judged on a half-open phase");
                }
                Settled::Counted
            }
            Verdict::Close => {
                // A recovered circuit starts a fresh window: the failures
                // that opened it must not judge the first call after it.
                self.start = 0;
                self.len = 0;
                self.transition(Phase::Closed);
                Settled::Closed
            }
            Verdict::Open => {
                self.open(event.at, draw);
                Settled::Opened
            }
        }
    }

    pub(super) fn open(&mut self, now: Duration, draw: u64) {
        let cooldown = self.policy.recovery().cooldown().delay(draw);
        self.transition(Phase::Open {
            opened_at: now,
            retry_at: now.saturating_add(cooldown),
        });
    }

    /// [`Refusal::Exhausted`] unless `needed` more epochs are left.
    pub(super) const fn check_epochs(&self, needed: u64) -> Result<(), Refusal> {
        if self.epoch.checked_add(needed).is_none() {
            return Err(Refusal::Exhausted);
        }
        Ok(())
    }

    /// Move to `phase` under the next epoch. Every caller checks with
    /// [`check_epochs`](Self::check_epochs) first, so the epoch is never
    /// reused.
    pub(super) const fn transition(&mut self, phase: Phase) {
        let Some(epoch) = self.epoch.checked_add(1) else {
            debug_assert!(false, "callers check the epochs left first");
            return;
        };
        self.phase = phase;
        self.epoch = epoch;
    }
}

#[cfg(test)]
mod tests;
