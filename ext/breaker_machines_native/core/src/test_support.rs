//! Fixtures shared by the unit test modules.

use crate::{Clock, MemoryStorage};
use alloc::boxed::Box;
use alloc::sync::Arc;
use core::sync::atomic::{AtomicU64, Ordering};
use core::time::Duration;

/// A [`Clock`] that only moves when a test advances it.
#[derive(Debug, Clone)]
pub struct ManualClock {
    nanos: Arc<AtomicU64>,
}

impl ManualClock {
    pub fn starting_at(secs: u64) -> Self {
        Self {
            nanos: Arc::new(AtomicU64::new(secs * 1_000_000_000)),
        }
    }

    pub fn advance(&self, by: Duration) {
        let nanos = u64::try_from(by.as_nanos()).expect("test steps fit in u64 nanoseconds");
        self.nanos.fetch_add(nanos, Ordering::SeqCst);
    }

    /// In-memory storage reading this clock.
    pub fn storage(&self) -> Arc<MemoryStorage> {
        Arc::new(MemoryStorage::with_clock(Box::new(self.clone())))
    }
}

impl Clock for ManualClock {
    fn now_secs(&self) -> f64 {
        Duration::from_nanos(self.nanos.load(Ordering::SeqCst)).as_secs_f64()
    }
}

/// Poll a future exactly once with a no-op waker.
#[cfg(feature = "async")]
pub fn poll_once<F: core::future::Future>(
    future: core::pin::Pin<&mut F>,
) -> core::task::Poll<F::Output> {
    future.poll(&mut core::task::Context::from_waker(
        core::task::Waker::noop(),
    ))
}
