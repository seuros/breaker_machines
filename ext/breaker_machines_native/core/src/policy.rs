//! Validated breaker configuration: when to open, how to recover, how much
//! to admit.

use chrono_machines::Constant;
use core::num::NonZeroU32;
use core::time::Duration;

/// When a closed circuit opens: an absolute failure count, a failure rate, or
/// whichever is crossed first.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Threshold {
    count: Option<NonZeroU32>,
    rate: Option<f64>,
    minimum_calls: u32,
}

impl Threshold {
    /// `count` failures in the window open the circuit; so does a failure
    /// share of at least `rate` once the window holds `minimum_calls`
    /// outcomes. `None` unless at least one of `count` and `rate` is set and
    /// `rate` is finite and in `0.0 < rate <= 1.0`.
    #[must_use]
    pub const fn new(
        count: Option<NonZeroU32>,
        rate: Option<f64>,
        minimum_calls: u32,
    ) -> Option<Self> {
        let rate_valid = match rate {
            Some(rate) => rate.is_finite() && rate > 0.0 && rate <= 1.0,
            None => count.is_some(),
        };
        if rate_valid {
            Some(Self {
                count,
                rate,
                minimum_calls,
            })
        } else {
            None
        }
    }

    /// Failures in the window that open the circuit.
    #[must_use]
    pub const fn count(&self) -> Option<NonZeroU32> {
        self.count
    }

    /// Failure share of the window that opens the circuit.
    #[must_use]
    pub const fn rate(&self) -> Option<f64> {
        self.rate
    }

    /// Outcomes the window must hold before `rate` is judged.
    #[must_use]
    pub const fn minimum_calls(&self) -> u32 {
        self.minimum_calls
    }

    /// Whether `failures` and `successes` seen in one window cross this
    /// threshold.
    #[must_use]
    pub fn exceeded(&self, failures: u32, successes: u32) -> bool {
        if self.count.is_some_and(|count| failures >= count.get()) {
            return true;
        }
        let Some(rate) = self.rate else {
            return false;
        };
        let total = failures.saturating_add(successes);
        total > 0 && total >= self.minimum_calls && f64::from(failures) / f64::from(total) >= rate
    }
}

/// How an open circuit recovers: the cooldown before the first probe and the
/// probes that decide between closing and reopening.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Recovery {
    cooldown: Constant,
    success_threshold: NonZeroU32,
    half_open_calls: NonZeroU32,
}

impl Recovery {
    /// An open circuit waits `cooldown`, shortened by up to `jitter` of it
    /// (drawn once per opening), then admits up to `half_open_calls` probes
    /// at a time; `success_threshold` successful probes close it and one
    /// failed probe reopens it. `None` unless `jitter` is in `0.0..=1.0`.
    #[must_use]
    pub fn new(
        cooldown: Duration,
        jitter: f64,
        success_threshold: NonZeroU32,
        half_open_calls: NonZeroU32,
    ) -> Option<Self> {
        Some(Self {
            cooldown: Constant::new(cooldown, jitter)?,
            success_threshold,
            half_open_calls,
        })
    }

    /// The cooldown as the chrono-machines strategy that draws it.
    #[must_use]
    pub const fn cooldown(&self) -> Constant {
        self.cooldown
    }

    /// Successful probes that close the circuit.
    #[must_use]
    pub const fn success_threshold(&self) -> NonZeroU32 {
        self.success_threshold
    }

    /// Probes admitted at a time while half-open.
    #[must_use]
    pub const fn half_open_calls(&self) -> NonZeroU32 {
        self.half_open_calls
    }
}

/// Everything a [`Breaker`](crate::Breaker) decides by.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Policy {
    threshold: Threshold,
    window: Duration,
    recovery: Recovery,
    max_concurrent: Option<NonZeroU32>,
}

impl Policy {
    /// Outcomes within the last `window` are judged by `threshold`; an open
    /// circuit recovers by `recovery`; at most `max_concurrent` tickets are
    /// outstanding at once (unbounded when `None`). `None` when `window` is
    /// zero.
    #[must_use]
    pub const fn new(
        threshold: Threshold,
        window: Duration,
        recovery: Recovery,
        max_concurrent: Option<NonZeroU32>,
    ) -> Option<Self> {
        if window.is_zero() {
            return None;
        }
        Some(Self {
            threshold,
            window,
            recovery,
            max_concurrent,
        })
    }

    /// When a closed circuit opens.
    #[must_use]
    pub const fn threshold(&self) -> Threshold {
        self.threshold
    }

    /// The span of the outcome window.
    #[must_use]
    pub const fn window(&self) -> Duration {
        self.window
    }

    /// How an open circuit recovers.
    #[must_use]
    pub const fn recovery(&self) -> Recovery {
        self.recovery
    }

    /// The most tickets outstanding at once, if bounded.
    #[must_use]
    pub const fn max_concurrent(&self) -> Option<NonZeroU32> {
        self.max_concurrent
    }
}

#[cfg(test)]
mod tests;
