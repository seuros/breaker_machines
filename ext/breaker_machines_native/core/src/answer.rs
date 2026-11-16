//! The breaker's public vocabulary: states, outcomes, tickets and answers.

use core::time::Duration;

/// Where a circuit is in its lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// Calls are admitted and their outcomes judged against the threshold.
    Closed,
    /// Calls are refused until the cooldown drawn on opening elapses.
    Open,
    /// A limited number of probes decide between closing and reopening.
    HalfOpen,
}

impl State {
    /// The state's name in `snake_case`.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Closed => "closed",
            Self::Open => "open",
            Self::HalfOpen => "half_open",
        }
    }
}

/// What a finished operation did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Outcome {
    /// It succeeded.
    #[default]
    Success,
    /// It failed in a way that counts against the circuit.
    Failure,
}

/// One outcome in the window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Event {
    /// When the outcome was recorded.
    pub at: Duration,
    /// What the operation did.
    pub outcome: Outcome,
    /// How long the operation ran.
    pub took: Duration,
}

/// What kind of admission a [`Ticket`] holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A call admitted while closed.
    Call,
    /// A half-open probe; it holds one probe slot.
    Probe,
}

/// Admission for one operation, settled by [`Breaker::complete`](crate::Breaker::complete) or
/// [`Breaker::abandon`](crate::Breaker::abandon).
///
/// Completing counts the outcome; abandoning does not. Either frees what the
/// ticket holds, and the ticket remembers how it was settled, so a repeat of
/// the same settlement is honoured as a duplicate and changes nothing. A
/// ticket dropped unsettled keeps its concurrency slot and, for a probe, its
/// probe slot until the circuit next changes state. Tickets are not `Clone`:
/// a copy could settle twice.
#[derive(Debug, PartialEq, Eq)]
#[must_use = "pass the ticket to `complete` or `abandon`"]
pub struct Ticket {
    pub(crate) id: u64,
    pub(crate) epoch: u64,
    pub(crate) admitted_at: Duration,
    pub(crate) kind: Kind,
    pub(crate) settled: Option<Settlement>,
}

/// How a ticket was settled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settlement {
    /// Completed with this outcome, which the breaker answered with this.
    Completed(Outcome, Settled),
    /// Abandoned.
    Abandoned,
}

impl Ticket {
    /// The scoped id the breaker issued this ticket under.
    #[must_use]
    pub const fn id(&self) -> u64 {
        self.id
    }

    /// The instant the ticket was admitted at.
    #[must_use]
    pub const fn admitted_at(&self) -> Duration {
        self.admitted_at
    }

    /// Whether this is a call or a probe.
    #[must_use]
    pub const fn kind(&self) -> Kind {
        self.kind
    }

    /// How the ticket was settled, once it was.
    #[must_use]
    pub const fn settled(&self) -> Option<Settlement> {
        self.settled
    }
}

/// An honoured [`Breaker::admit`](crate::Breaker::admit).
#[derive(Debug, PartialEq, Eq)]
#[must_use = "pass the ticket to `complete` or `abandon`"]
pub enum Admitted {
    /// The circuit is closed; the ticket is a call.
    Call(Ticket),
    /// The circuit is half-open; the ticket holds a probe slot.
    Probe(Ticket),
    /// The cooldown had elapsed: this admission moved the circuit from open
    /// to half-open, and the ticket is its first probe.
    HalfOpened(Ticket),
}

impl Admitted {
    /// The ticket, whichever way it was admitted.
    pub const fn into_ticket(self) -> Ticket {
        match self {
            Self::Call(ticket) | Self::Probe(ticket) | Self::HalfOpened(ticket) => ticket,
        }
    }
}

/// What a recorded outcome did to the circuit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settled {
    /// It was recorded; the state is unchanged.
    Counted,
    /// It opened the circuit (a closed circuit crossed its threshold, or a
    /// probe failed).
    Opened,
    /// It was the probe success that closed the circuit.
    Closed,
}

/// What [`Breaker::observe`](crate::Breaker::observe) did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Observed {
    /// The outcome settled in the state the circuit was in.
    Settled(Settled),
    /// The cooldown had elapsed: the circuit moved from open to half-open
    /// first, then the outcome settled there.
    HalfOpened(Settled),
}

/// What [`Breaker::complete`](crate::Breaker::complete) did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Completed {
    /// The outcome was recorded and settled so.
    Settled(Settled),
    /// The ticket was already completed with this outcome: nothing changed;
    /// this is the original answer.
    Duplicate(Settled),
}

/// What [`Breaker::abandon`](crate::Breaker::abandon) did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Abandoned {
    /// The ticket's slots were freed.
    Released,
    /// The ticket was already abandoned; nothing changed.
    Duplicate,
}

/// What [`Breaker::force_close`](crate::Breaker::force_close) did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForceClosed {
    /// The circuit was open or half-open and is now closed.
    Closed,
    /// The circuit was already closed; nothing changed.
    AlreadyClosed,
}

/// The part of a breaker's state that may cross a process boundary: where
/// it is in its lifecycle and, while open, when it opened and may probe.
/// Instants are on the clock every sharer reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Status {
    state: State,
    opened_at: Option<Duration>,
    retry_at: Option<Duration>,
}

impl Status {
    /// `None` unless an open status carries both instants with
    /// `opened_at <= retry_at`, and a closed or half-open one neither.
    #[must_use]
    pub const fn new(
        state: State,
        opened_at: Option<Duration>,
        retry_at: Option<Duration>,
    ) -> Option<Self> {
        let valid = match state {
            State::Open => match (opened_at, retry_at) {
                (Some(opened), Some(retry)) => opened.as_nanos() <= retry.as_nanos(),
                (None, _) | (_, None) => false,
            },
            State::Closed | State::HalfOpen => opened_at.is_none() && retry_at.is_none(),
        };
        if valid {
            Some(Self {
                state,
                opened_at,
                retry_at,
            })
        } else {
            None
        }
    }

    /// The lifecycle state.
    #[must_use]
    pub const fn state(&self) -> State {
        self.state
    }

    /// Closed, with no instants.
    #[must_use]
    pub const fn closed() -> Self {
        Self {
            state: State::Closed,
            opened_at: None,
            retry_at: None,
        }
    }

    /// When the circuit opened, while open.
    #[must_use]
    pub const fn opened_at(&self) -> Option<Duration> {
        self.opened_at
    }

    /// When a probe may run, while open.
    #[must_use]
    pub const fn retry_at(&self) -> Option<Duration> {
        self.retry_at
    }
}

/// What [`Breaker::adopt`](crate::Breaker::adopt) did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Adopted {
    /// The breaker already had this status; nothing changed.
    Unchanged,
    /// The breaker is now open, on the status's instants.
    Opened,
    /// The breaker is now closed, with a fresh window.
    Closed,
    /// The breaker is now half-open, with no probes taken.
    HalfOpened,
}
