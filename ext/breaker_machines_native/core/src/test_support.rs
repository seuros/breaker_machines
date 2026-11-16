//! Fixtures shared by the runtime test modules.

use crate::{Clock, Policy, Recovery, Threshold};
use core::num::NonZeroU32;
use core::sync::atomic::{AtomicU64, Ordering};
use core::time::Duration;
use std::sync::Arc;

/// A [`Clock`] that only moves when a test advances it.
#[derive(Debug, Clone, Default)]
pub struct ManualClock {
    nanos: Arc<AtomicU64>,
}

impl ManualClock {
    pub fn advance(&self, by: Duration) {
        let nanos = u64::try_from(by.as_nanos()).unwrap_or(u64::MAX);
        self.nanos.fetch_add(nanos, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now(&self) -> Duration {
        Duration::from_nanos(self.nanos.load(Ordering::SeqCst))
    }
}

fn nz(n: u32) -> NonZeroU32 {
    NonZeroU32::new(n).unwrap_or(NonZeroU32::MIN)
}

/// `failures` in a 60 s window open it; a 30 s cooldown; `successes`
/// probes close it, `probes` at a time; at most `limit` in flight.
pub fn policy(failures: u32, successes: u32, probes: u32, limit: Option<u32>) -> Policy {
    let threshold = Threshold::new(Some(nz(failures)), None, 0);
    let recovery = Recovery::new(Duration::from_secs(30), 0.0, nz(successes), nz(probes));
    threshold
        .zip(recovery)
        .and_then(|(threshold, recovery)| {
            Policy::new(threshold, Duration::from_secs(60), recovery, limit.map(nz))
        })
        .unwrap_or_else(|| panic!("test policies are valid"))
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
