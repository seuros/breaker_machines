//! Fixtures shared by the unit test modules.

use crate::{Clock, MemoryStorage};
use alloc::boxed::Box;
use alloc::sync::Arc;
use core::sync::atomic::{AtomicU64, Ordering};
use core::time::Duration;

/// A [`Clock`] that only moves when a test advances it.
#[derive(Debug, Clone)]
pub(crate) struct ManualClock {
    nanos: Arc<AtomicU64>,
}

impl ManualClock {
    pub(crate) fn starting_at(secs: u64) -> Self {
        Self {
            nanos: Arc::new(AtomicU64::new(secs * 1_000_000_000)),
        }
    }

    pub(crate) fn advance(&self, by: Duration) {
        self.nanos.fetch_add(by.as_nanos() as u64, Ordering::SeqCst);
    }

    /// In-memory storage reading this clock.
    pub(crate) fn storage(&self) -> Arc<MemoryStorage> {
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
pub(crate) fn poll_once<F: core::future::Future>(
    future: core::pin::Pin<&mut F>,
) -> core::task::Poll<F::Output> {
    future.poll(&mut core::task::Context::from_waker(
        core::task::Waker::noop(),
    ))
}
