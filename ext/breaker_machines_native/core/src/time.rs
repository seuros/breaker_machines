//! Monotonic time source for the circuit breaker.

/// A monotonic time source, reported as fractional seconds from a fixed origin.
///
/// Readings must be non-decreasing; only differences are meaningful.
pub trait Clock: Send + Sync + core::fmt::Debug {
    /// Seconds elapsed since this clock's fixed origin.
    fn now_secs(&self) -> f64;
}

/// A [`Clock`] that always reports `0.0`. Default on `no_std`; with it,
/// [`MemoryStorage`](crate::MemoryStorage) sliding windows count all retained
/// events. Inject a real clock via `MemoryStorage::with_clock`.
#[derive(Debug, Clone, Copy, Default)]
pub struct ZeroClock;

impl Clock for ZeroClock {
    fn now_secs(&self) -> f64 {
        0.0
    }
}

/// [`Clock`] backed by `std::time::Instant`.
#[cfg(feature = "std")]
#[derive(Debug, Clone)]
pub struct SystemClock {
    origin: std::time::Instant,
}

#[cfg(feature = "std")]
impl SystemClock {
    /// Create a clock whose origin is the moment of construction.
    pub fn new() -> Self {
        Self {
            origin: std::time::Instant::now(),
        }
    }
}

#[cfg(feature = "std")]
impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "std")]
impl Clock for SystemClock {
    fn now_secs(&self) -> f64 {
        self.origin.elapsed().as_secs_f64()
    }
}

#[cfg(all(test, feature = "std"))]
mod tests {
    use super::*;

    #[test]
    fn system_clock_is_monotonic() {
        let clock = SystemClock::new();
        let a = clock.now_secs();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let b = clock.now_secs();
        assert!(b >= a, "clock went backwards: {a} -> {b}");
    }
}
