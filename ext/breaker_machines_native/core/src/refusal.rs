//! Every reason a breaker declines a call.

use core::fmt;

/// Why a [`Breaker`](crate::Breaker) declined a call. A refusal changes
/// nothing: no counter, no window entry, no recorded instant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The circuit is open and its cooldown has not elapsed at the instant
    /// supplied. Like every refusal it is an answer about that instant, not
    /// a recorded fact.
    Open,
    /// Every half-open probe slot is taken.
    Busy,
    /// The concurrency limit is reached: as many tickets are outstanding as
    /// the policy allows.
    Full,
    /// `now` is earlier than the latest honoured instant.
    TimeRegression,
    /// The ticket is not this breaker's: it carries another scope, or this
    /// breaker never issued its sequence number. Refused before any lookup.
    Unknown,
    /// The ticket was already settled the other way: abandoned and now
    /// completed, completed and now abandoned, or completed with the other
    /// outcome.
    Mismatch,
    /// An identity the call needs is used up, and identities never wrap:
    /// every ticket id of this scope (2^48 - 1) has been issued, or the
    /// call would transition and every transition epoch (`u64::MAX`) has
    /// been taken.
    Exhausted,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Open => "the circuit is open",
            Self::Busy => "every half-open probe slot is taken",
            Self::Full => "the concurrency limit is reached",
            Self::TimeRegression => "time is earlier than the latest honoured instant",
            Self::Unknown => "the ticket is not this breaker's",
            Self::Mismatch => "the ticket was already settled the other way",
            Self::Exhausted => "every ticket id or transition epoch has been used",
        })
    }
}

impl core::error::Error for Refusal {}
