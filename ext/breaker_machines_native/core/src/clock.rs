//! Monotonic time sources for the runtime layer.

use core::time::Duration;
use std::time::Instant;

/// A monotonic time source: the time elapsed since an origin it picks.
/// Readings should never decrease; a reading earlier than the latest one a
/// circuit honoured is treated as that latest instant.
pub trait Clock: Send + Sync + core::fmt::Debug {
    /// Time elapsed since this clock's origin.
    fn now(&self) -> Duration;
}

/// A [`Clock`] backed by [`Instant`], with its origin at construction.
#[derive(Debug, Clone, Copy)]
pub struct SystemClock {
    origin: Instant,
}

impl SystemClock {
    /// A clock whose origin is now.
    #[must_use]
    pub fn new() -> Self {
        Self {
            origin: Instant::now(),
        }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn now(&self) -> Duration {
        self.origin.elapsed()
    }
}

/// Random draws for jittered cooldowns: splitmix64 seeded from the
/// process's hash randomness, so circuits in different processes spread.
#[derive(Debug, Clone, Copy)]
pub struct Draws(u64);

impl Draws {
    pub fn new() -> Self {
        use core::hash::BuildHasher;
        Self(std::hash::RandomState::new().hash_one(Instant::now()))
    }

    pub const fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}
