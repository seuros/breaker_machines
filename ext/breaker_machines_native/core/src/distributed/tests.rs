use super::*;
use crate::test_support::{ManualClock, poll_once};
use crate::{MemoryStorage, StorageBackend};
use core::assert_matches;
use core::future::pending;
use core::time::Duration;

fn test_breaker(store: Arc<MemoryStorage>, name: &str) -> DistributedCircuitBreaker {
    crate::CircuitBreaker::builder(name)
        .failure_threshold(1)
        .half_open_timeout_secs(10.0)
        .probe_timeout_secs(2.0)
        .success_threshold(1)
        .build_distributed(store)
}

fn acquired(decision: ProbeDecision) -> ProbeLease {
    match decision {
        ProbeDecision::Acquired { lease, .. } => lease,
        decision => panic!("expected an acquired probe, got {decision:?}"),
    }
}

#[test]
fn gateways_share_state_and_opened_at() {
    pollster::block_on(async {
        let store = ManualClock::starting_at(100).storage();
        let gateway_a = test_breaker(store.clone(), "payments");
        let gateway_b = test_breaker(store, "payments");

        let result = gateway_a
            .call(|| async { Err::<(), _>("service unavailable") })
            .await;
        assert_matches!(result, Err(CircuitError::Execution("service unavailable")));

        assert_matches!(
            gateway_b.state().await,
            Ok(CircuitSnapshot {
                state: SharedCircuitState::Open,
                opened_at: Some(100.0),
                retry_at: Some(110.0),
                ..
            })
        );

        let rejected = gateway_b.call(|| async { Ok::<_, &str>(()) }).await;
        assert_matches!(
            rejected,
            Err(CircuitError::Open {
                opened_at: 100.0,
                ..
            })
        );
    });
}

#[test]
fn gateways_share_the_failure_rate_window() {
    pollster::block_on(async {
        let store = Arc::new(MemoryStorage::new());
        let gateway = |store| {
            crate::CircuitBreaker::builder("search")
                .disable_failure_threshold()
                .failure_rate(0.5)
                .minimum_calls(4)
                .build_distributed(store)
        };
        let gateway_a = gateway(store.clone());
        let gateway_b = gateway(store);

        for _ in 0..2 {
            assert_matches!(gateway_a.call(|| async { Ok::<_, &str>(()) }).await, Ok(()));
            let _ = gateway_b.call(|| async { Err::<(), _>("failure") }).await;
        }

        assert_matches!(
            gateway_a.state().await,
            Ok(CircuitSnapshot {
                state: SharedCircuitState::Open,
                generation: 1,
                ..
            })
        );
    });
}

#[test]
fn only_one_gateway_owns_probe_and_expired_lease_recovers() {
    pollster::block_on(async {
        let clock = ManualClock::starting_at(100);
        let store = clock.storage();
        let gateway_a = test_breaker(store.clone(), "payments");
        let gateway_b = test_breaker(store, "payments");

        let _ = gateway_a
            .call(|| async { Err::<(), _>("service unavailable") })
            .await;
        clock.advance(Duration::from_secs(10));

        let mut first_probe = Box::pin(gateway_a.call(pending::<Result<(), &str>>));
        assert!(poll_once(first_probe.as_mut()).is_pending());

        let competing = gateway_b.call(|| async { Ok::<_, &str>(()) }).await;
        assert_matches!(competing, Err(CircuitError::HalfOpenLimitReached { .. }));

        // The elected gateway goes away; its lease expires after probe_timeout.
        drop(first_probe);
        clock.advance(Duration::from_secs(2));

        assert_matches!(gateway_b.call(|| async { Ok::<_, &str>(()) }).await, Ok(()));
        assert_matches!(gateway_a.is_closed().await, Ok(true));
    });
}

#[test]
fn stale_probe_token_cannot_transition_new_generation() {
    pollster::block_on(async {
        let clock = ManualClock::starting_at(10);
        let store = clock.storage();
        let failure_policy = FailurePolicy {
            failure_threshold: Some(1),
            failure_rate_threshold: None,
            minimum_calls: 1,
            failure_window_secs: 60.0,
            open_timeout_secs: 1.0,
        };
        let probe_policy = ProbePolicy {
            success_threshold: 1,
            open_timeout_secs: 1.0,
        };

        store
            .record_outcome("api", 0, StoredOutcome::Failure, 0.1, failure_policy)
            .await
            .unwrap();
        clock.advance(Duration::from_secs(1));

        let first = acquired(store.try_begin_probe("api", 1.0).await.unwrap());
        clock.advance(Duration::from_secs(1));
        let second = acquired(store.try_begin_probe("api", 1.0).await.unwrap());

        let stale = store
            .complete_probe("api", first, StoredOutcome::Failure, 0.1, probe_policy)
            .await;
        assert_matches!(
            stale,
            Ok(StorageUpdate {
                applied: false,
                transition: None,
                snapshot: CircuitSnapshot {
                    state: SharedCircuitState::HalfOpen,
                    ..
                },
            })
        );
        assert_eq!(store.event_log("api", 10).len(), 1);

        let current = store
            .complete_probe("api", second, StoredOutcome::Success, 0.1, probe_policy)
            .await;
        assert_matches!(
            current,
            Ok(StorageUpdate {
                applied: true,
                transition: Some(StateTransition::Closed),
                snapshot: CircuitSnapshot {
                    state: SharedCircuitState::Closed,
                    ..
                },
            })
        );
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
            .await;

        assert_matches!(
            stale,
            Ok(StorageUpdate {
                applied: false,
                snapshot: CircuitSnapshot {
                    state: SharedCircuitState::Closed,
                    ..
                },
                ..
            })
        );
        assert!(store.event_log("api", 10).is_empty());
    });
}

#[test]
fn distributed_call_future_is_send_when_operation_is_send() {
    fn assert_send<T: Send>(_: T) {}

    let gateway = test_breaker(Arc::new(MemoryStorage::new()), "payments");
    assert_send(gateway.call(|| async { Ok::<_, String>(()) }));
}
