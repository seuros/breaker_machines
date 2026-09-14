use super::*;
use crate::{Clock, MemoryStorage};
use core::future::{Future, pending};
use core::pin::Pin;
use core::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll, Waker};

#[derive(Debug, Clone)]
struct ManualClock {
    millis: Arc<AtomicU64>,
}

impl ManualClock {
    fn new(seconds: u64) -> Self {
        Self {
            millis: Arc::new(AtomicU64::new(seconds * 1000)),
        }
    }

    fn advance(&self, seconds: u64) {
        self.millis.fetch_add(seconds * 1000, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_secs(&self) -> f64 {
        self.millis.load(Ordering::SeqCst) as f64 / 1000.0
    }
}

fn poll_once<F: Future>(future: Pin<&mut F>) -> Poll<F::Output> {
    let waker = Waker::noop();
    let mut context = Context::from_waker(waker);
    Future::poll(future, &mut context)
}

fn test_breaker(store: Arc<MemoryStorage>, name: &str) -> DistributedCircuitBreaker {
    crate::CircuitBreaker::builder(name)
        .failure_threshold(1)
        .half_open_timeout_secs(10.0)
        .probe_timeout_secs(2.0)
        .success_threshold(1)
        .build_distributed(store)
}

#[test]
fn gateways_share_state_and_opened_at() {
    pollster::block_on(async {
        let clock = ManualClock::new(100);
        let store = Arc::new(MemoryStorage::with_clock(Box::new(clock)));
        let gateway_a = test_breaker(store.clone(), "payments");
        let gateway_b = test_breaker(store, "payments");

        let result = gateway_a
            .call(|| async { Err::<(), _>("service unavailable") })
            .await;
        assert!(matches!(result, Err(CircuitError::Execution(_))));

        let snapshot = gateway_b.state().await.unwrap();
        assert_eq!(snapshot.state, SharedCircuitState::Open);
        assert_eq!(snapshot.opened_at, Some(100.0));
        assert_eq!(snapshot.retry_at, Some(110.0));

        let rejected = gateway_b.call(|| async { Ok::<_, &str>(()) }).await;
        assert!(matches!(
            rejected,
            Err(CircuitError::Open {
                opened_at: 100.0,
                ..
            })
        ));
    });
}

#[test]
fn gateways_share_the_failure_rate_window() {
    pollster::block_on(async {
        let store = Arc::new(MemoryStorage::new());
        let gateway_a = crate::CircuitBreaker::builder("search")
            .disable_failure_threshold()
            .failure_rate(0.5)
            .minimum_calls(4)
            .build_distributed(store.clone());
        let gateway_b = crate::CircuitBreaker::builder("search")
            .disable_failure_threshold()
            .failure_rate(0.5)
            .minimum_calls(4)
            .build_distributed(store);

        gateway_a
            .call(|| async { Ok::<_, &str>(()) })
            .await
            .unwrap();
        let _ = gateway_b
            .call(|| async { Err::<(), _>("first failure") })
            .await;
        gateway_a
            .call(|| async { Ok::<_, &str>(()) })
            .await
            .unwrap();
        let _ = gateway_b
            .call(|| async { Err::<(), _>("second failure") })
            .await;

        assert!(gateway_a.is_open().await.unwrap());
        assert_eq!(gateway_a.state().await.unwrap().generation, 1);
    });
}

#[test]
fn only_one_gateway_owns_probe_and_expired_lease_recovers() {
    pollster::block_on(async {
        let clock = ManualClock::new(100);
        let store = Arc::new(MemoryStorage::with_clock(Box::new(clock.clone())));
        let gateway_a = test_breaker(store.clone(), "payments");
        let gateway_b = test_breaker(store, "payments");

        let _ = gateway_a
            .call(|| async { Err::<(), _>("service unavailable") })
            .await;
        clock.advance(10);

        let mut first_probe = Box::pin(gateway_a.call(pending::<Result<(), &str>>));
        assert!(poll_once(first_probe.as_mut()).is_pending());

        let competing = gateway_b.call(|| async { Ok::<_, &str>(()) }).await;
        assert!(matches!(
            competing,
            Err(CircuitError::HalfOpenLimitReached { .. })
        ));

        drop(first_probe);
        clock.advance(2);

        gateway_b
            .call(|| async { Ok::<_, &str>(()) })
            .await
            .unwrap();
        assert!(gateway_a.is_closed().await.unwrap());
    });
}

#[test]
fn stale_probe_token_cannot_transition_new_generation() {
    pollster::block_on(async {
        let clock = ManualClock::new(10);
        let store = MemoryStorage::with_clock(Box::new(clock.clone()));
        let policy = FailurePolicy {
            failure_threshold: Some(1),
            failure_rate_threshold: None,
            minimum_calls: 1,
            failure_window_secs: 60.0,
            open_timeout_secs: 1.0,
        };

        store
            .record_outcome("api", 0, StoredOutcome::Failure, 0.1, policy)
            .await
            .unwrap();
        clock.advance(1);

        let first = match store.try_begin_probe("api", 1.0).await.unwrap() {
            ProbeDecision::Acquired { lease, .. } => lease,
            decision => panic!("expected first probe, got {decision:?}"),
        };
        clock.advance(1);
        let second = match store.try_begin_probe("api", 1.0).await.unwrap() {
            ProbeDecision::Acquired { lease, .. } => lease,
            decision => panic!("expected replacement probe, got {decision:?}"),
        };

        let stale = store
            .complete_probe(
                "api",
                first,
                StoredOutcome::Failure,
                0.1,
                ProbePolicy {
                    success_threshold: 1,
                    open_timeout_secs: 1.0,
                },
            )
            .await
            .unwrap();
        assert!(!stale.applied);
        assert_eq!(stale.snapshot.state, SharedCircuitState::HalfOpen);
        assert_eq!(crate::StorageBackend::event_log(&store, "api", 10).len(), 1);

        let current = store
            .complete_probe(
                "api",
                second,
                StoredOutcome::Success,
                0.1,
                ProbePolicy {
                    success_threshold: 1,
                    open_timeout_secs: 1.0,
                },
            )
            .await
            .unwrap();
        assert!(current.applied);
        assert_eq!(current.transition, Some(StateTransition::Closed));
        assert_eq!(current.snapshot.state, SharedCircuitState::Closed);
    });
}

#[test]
fn reset_fences_normal_calls_from_the_previous_generation() {
    pollster::block_on(async {
        let store = MemoryStorage::new();
        let admitted = store.load_state("api").await.unwrap();
        let reset = AsyncStorageBackend::reset(&store, "api").await.unwrap();

        assert_eq!(reset.generation, admitted.generation + 1);

        let stale = store
            .record_outcome(
                "api",
                admitted.generation,
                StoredOutcome::Failure,
                0.1,
                FailurePolicy {
                    failure_threshold: Some(1),
                    failure_rate_threshold: None,
                    minimum_calls: 1,
                    failure_window_secs: 60.0,
                    open_timeout_secs: 10.0,
                },
            )
            .await
            .unwrap();

        assert!(!stale.applied);
        assert_eq!(stale.snapshot.state, SharedCircuitState::Closed);
        assert!(crate::StorageBackend::event_log(&store, "api", 10).is_empty());
    });
}

#[test]
fn distributed_call_future_is_send_when_operation_is_send() {
    fn assert_send<T: Send>(_: T) {}

    let store = Arc::new(MemoryStorage::new());
    let gateway = test_breaker(store, "payments");
    assert_send(gateway.call(|| async { Ok::<_, String>(()) }));
}
