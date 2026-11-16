use super::*;
use crate::test_support::{ManualClock, policy, poll_once};
use crate::{CircuitBreaker, MemoryStorage};
use core::assert_matches;
use core::future::pending;
use core::task::Poll;
use std::boxed::Box;

fn gateway(store: &Arc<MemoryStorage>, limit: Option<u32>) -> DistributedCircuitBreaker {
    CircuitBreaker::builder("payments", policy(1, 1, 1, limit)).build_distributed(
        Arc::clone(store) as Arc<dyn AsyncStorageBackend>,
        Duration::from_secs(2),
    )
}

#[test]
fn gateways_share_one_state_machine() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = Arc::new(MemoryStorage::with_clock(clock.clone()));
        let a = gateway(&store, None);
        let b = gateway(&store, None);
        assert_matches!(
            a.call(|| async { Err::<(), _>("down") }).await,
            Err(CircuitError::Execution("down"))
        );
        assert_eq!(b.state().await, Ok(State::Open));
        assert_matches!(
            b.call(|| async { Ok::<_, &str>(()) }).await,
            Err(CircuitError::Refused {
                refusal: Refusal::Open,
                ..
            })
        );
        clock.advance(Duration::from_secs(30));
        assert_matches!(b.call(|| async { Ok::<_, &str>(()) }).await, Ok(()));
        assert_eq!(a.state().await, Ok(State::Closed));
        assert_eq!(a.snapshot().await.map(|s| s.generation), Ok(3));
        let reset = a.reset().await.expect("reset");
        assert_eq!(reset.generation, 4);
        assert_eq!(a.name(), "payments");
    });
}

#[test]
fn another_node_holding_the_lease_is_busy() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = Arc::new(MemoryStorage::with_clock(clock.clone()));
        let a = gateway(&store, None);
        let b = gateway(&store, None);
        assert!(a.call(|| async { Err::<(), _>("down") }).await.is_err());
        clock.advance(Duration::from_secs(30));
        let mut parked = Box::pin(a.call(pending::<Result<(), &str>>));
        assert_matches!(poll_once(parked.as_mut()), Poll::Pending);
        assert_matches!(
            b.call(|| async { Ok::<_, &str>(()) }).await,
            Err(CircuitError::Refused {
                refusal: Refusal::Busy,
                ..
            })
        );
    });
}

#[test]
fn the_node_concurrency_limit_is_full() {
    pollster::block_on(async {
        let store = Arc::new(MemoryStorage::new());
        let a = gateway(&store, Some(1));
        let mut parked = Box::pin(a.call(pending::<Result<(), &str>>));
        assert_matches!(poll_once(parked.as_mut()), Poll::Pending);
        assert_matches!(
            a.call(|| async { Ok::<_, &str>(()) }).await,
            Err(CircuitError::Refused {
                refusal: Refusal::Full,
                ..
            })
        );
        drop(parked);
        assert_matches!(a.call(|| async { Ok::<_, &str>(()) }).await, Ok(()));
    });
}

#[test]
fn a_full_node_never_admits_even_at_the_counter_limit() {
    // At `u32::MAX` in flight, incrementing first would wrap the counter to
    // zero for an instant, and a racing call would be admitted past the
    // limit. Admission checks and increments in one step instead.
    let store = Arc::new(MemoryStorage::new());
    let node = gateway(&store, Some(u32::MAX));
    node.in_flight.store(u32::MAX, Ordering::SeqCst);
    let admitted = core::sync::atomic::AtomicU32::new(0);
    std::thread::scope(|scope| {
        for _ in 0..4 {
            scope.spawn(|| {
                for _ in 0..200_000 {
                    if node.take_slot().is_ok() {
                        admitted.fetch_add(1, Ordering::SeqCst);
                    }
                }
            });
        }
    });
    assert_eq!(
        admitted.load(Ordering::SeqCst),
        0,
        "admitted past the limit"
    );
    assert_eq!(node.in_flight.load(Ordering::SeqCst), u32::MAX);
}
