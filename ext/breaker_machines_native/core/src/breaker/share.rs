//! Sharing a breaker's lifecycle with breakers in other processes.

use super::{Breaker, Phase};
use crate::{Adopted, Refusal, State, Status};

impl<const N: usize> Breaker<N> {
    /// The lifecycle part of this breaker's state, to share with breakers
    /// in other processes.
    #[must_use]
    pub fn status(&self) -> Status {
        Status::new(self.state(), self.opened_at(), self.retry_at()).unwrap_or_else(|| {
            debug_assert!(false, "an open phase holds opened_at <= retry_at");
            Status::closed()
        })
    }

    /// Take on a status another breaker shared. An open status keeps its
    /// instants (they must be on this breaker's clock); a closed one starts
    /// a fresh window, as recovering does; a half-open one has no probes
    /// taken. Tickets outstanding keep their slots but can no longer drive
    /// a transition. The caller decides which shared status is newer: a
    /// stale one adopted here undoes a newer local transition.
    ///
    /// # Errors
    ///
    /// [`Refusal::Exhausted`] when the status differs and no epoch is left
    /// for the transition.
    pub fn adopt(&mut self, status: Status) -> Result<Adopted, Refusal> {
        if self.status() == status {
            return Ok(Adopted::Unchanged);
        }
        self.check_epochs(1)?;
        Ok(
            match (status.state(), status.opened_at().zip(status.retry_at())) {
                (State::Open, Some((opened_at, retry_at))) => {
                    self.transition(Phase::Open {
                        opened_at,
                        retry_at,
                    });
                    Adopted::Opened
                }
                (State::Open, None) => {
                    debug_assert!(false, "Status::new gives an open status both instants");
                    Adopted::Unchanged
                }
                (State::HalfOpen, _) => {
                    self.transition(Phase::HalfOpen {
                        successes: 0,
                        in_flight: 0,
                    });
                    Adopted::HalfOpened
                }
                (State::Closed, _) => {
                    self.start = 0;
                    self.len = 0;
                    self.transition(Phase::Closed);
                    Adopted::Closed
                }
            },
        )
    }
}

#[cfg(test)]
mod tests;
