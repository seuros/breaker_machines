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

/// A store whose state reads as `state` and whose every other operation
/// fails with `kind`.
#[derive(Debug)]
struct Failing {
    state: State,
    kind: StorageErrorKind,
}

impl Failing {
    fn gateway(state: State, kind: StorageErrorKind) -> DistributedCircuitBreaker {
        CircuitBreaker::builder("payments", policy(1, 1, 1, None)).build_distributed(
            Arc::new(Self { state, kind }) as Arc<dyn AsyncStorageBackend>,
            Duration::from_secs(2),
        )
    }

    fn fail<'a, T: 'a>(&self) -> crate::StorageFuture<'a, T> {
        let error = StorageError::new(self.kind, "refused");
        Box::pin(async move { Err(error) })
    }
}

impl AsyncStorageBackend for Failing {
    fn load_state<'a>(&'a self, _: &'a str) -> crate::StorageFuture<'a, CircuitSnapshot> {
        let snapshot = CircuitSnapshot {
            state: self.state,
            ..CircuitSnapshot::default()
        };
        Box::pin(async move { Ok(snapshot) })
    }

    fn record_outcome<'a>(
        &'a self,
        _: &'a str,
        _: u64,
        _: StoredOutcome,
        _: Duration,
        _: FailurePolicy,
    ) -> crate::StorageFuture<'a, StorageUpdate> {
        self.fail()
    }

    fn try_begin_probe<'a>(
        &'a self,
        _: &'a str,
        _: Duration,
    ) -> crate::StorageFuture<'a, ProbeDecision> {
        self.fail()
    }

    fn complete_probe<'a>(
        &'a self,
        _: &'a str,
        _: ProbeLease,
        _: StoredOutcome,
        _: Duration,
        _: ProbePolicy,
    ) -> crate::StorageFuture<'a, StorageUpdate> {
        self.fail()
    }

    fn reset<'a>(&'a self, _: &'a str) -> crate::StorageFuture<'a, CircuitSnapshot> {
        self.fail()
    }
}

// Bug: a store out of generations or probe tokens surfaced as
// CircuitError::Storage, indistinguishable from a backend failure.
#[test]
fn an_exhausted_store_refuses_as_exhausted() {
    pollster::block_on(async {
        // Electing a probe needs a generation or token: refused, fallback runs.
        let open = Failing::gateway(State::Open, StorageErrorKind::Exhausted);
        assert_matches!(
            open.call(|| async { Ok::<_, &str>(()) }).await,
            Err(CircuitError::Refused {
                refusal: Refusal::Exhausted,
                ..
            })
        );
        let answered = open
            .call_with_fallback(
                || async { Ok::<_, &str>("ran") },
                |context| async move {
                    assert_eq!(context.refusal, Refusal::Exhausted);
                    Ok("fallback")
                },
            )
            .await;
        assert_matches!(answered, Ok("fallback"));

        // Recording an outcome that would transition: refused, as the local
        // circuit refuses settling with no epoch left.
        let closed = Failing::gateway(State::Closed, StorageErrorKind::Exhausted);
        assert_matches!(
            closed.call(|| async { Err::<(), _>("down") }).await,
            Err(CircuitError::Refused {
                refusal: Refusal::Exhausted,
                ..
            })
        );
        assert_matches!(
            closed.reset().await,
            Err(CircuitError::Refused {
                refusal: Refusal::Exhausted,
                ..
            })
        );
    });
}

#[test]
fn a_failing_backend_is_a_storage_error() {
    pollster::block_on(async {
        let open = Failing::gateway(State::Open, StorageErrorKind::Backend);
        let answered = open
            .call_with_fallback(
                || async { Ok::<_, &str>(()) },
                |_| async { panic!("a backend failure is no refusal") },
            )
            .await;
        assert_matches!(
            answered,
            Err(CircuitError::Storage(error)) if error.kind() == StorageErrorKind::Backend
        );

        let closed = Failing::gateway(State::Closed, StorageErrorKind::Backend);
        assert_matches!(
            closed.call(|| async { Err::<(), _>("down") }).await,
            Err(CircuitError::Storage(error)) if error.kind() == StorageErrorKind::Backend
        );
        assert_matches!(
            closed.reset().await,
            Err(CircuitError::Storage(error)) if error.kind() == StorageErrorKind::Backend
        );
    });
}

#[test]
fn an_exhausted_memory_store_refuses_the_gateway() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = Arc::new(MemoryStorage::with_clock(clock.clone()));
        store.exhaust_generations("payments");
        let gateway = gateway(&store, None);
        let before = gateway.snapshot().await;
        assert_matches!(
            gateway.call(|| async { Err::<(), _>("down") }).await,
            Err(CircuitError::Refused {
                refusal: Refusal::Exhausted,
                ..
            })
        );
        assert_eq!(gateway.snapshot().await, before, "nothing changed");
    });
}
