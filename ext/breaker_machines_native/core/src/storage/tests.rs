use super::*;
use crate::test_support::ManualClock;
use core::assert_matches;

fn store(clock: &ManualClock) -> MemoryStorage {
    MemoryStorage::with_clock(clock.clone())
}

fn failure_policy(count: u32) -> FailurePolicy {
    FailurePolicy {
        threshold: Threshold::new(NonZeroU32::new(count), None, 0).expect("valid"),
        window: Duration::from_secs(60),
        cooldown: Duration::from_secs(10),
    }
}

fn probe_policy(successes: u32) -> ProbePolicy {
    ProbePolicy {
        success_threshold: NonZeroU32::new(successes).expect("positive"),
        cooldown: Duration::from_secs(10),
    }
}

fn acquired(decision: ProbeDecision) -> ProbeLease {
    match decision {
        ProbeDecision::Acquired { lease, .. } => lease,
        other => panic!("expected an acquired probe, got {other:?}"),
    }
}

#[test]
fn outcomes_open_at_the_threshold_and_stale_generations_change_nothing() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = store(&clock);
        let first = store
            .record_outcome(
                "a",
                0,
                StoredOutcome::Failure,
                Duration::ZERO,
                failure_policy(2),
            )
            .await
            .expect("recorded");
        assert_eq!(first.transition, None);
        clock.advance(Duration::from_secs(1));
        let second = store
            .record_outcome(
                "a",
                0,
                StoredOutcome::Failure,
                Duration::ZERO,
                failure_policy(2),
            )
            .await
            .expect("recorded");
        assert_eq!(second.transition, Some(StateTransition::Opened));
        assert_eq!(second.snapshot.opened_at, Some(Duration::from_secs(1)));
        assert_eq!(second.snapshot.retry_at, Some(Duration::from_secs(11)));
        let stale = store
            .record_outcome(
                "a",
                0,
                StoredOutcome::Failure,
                Duration::ZERO,
                failure_policy(2),
            )
            .await
            .expect("answered");
        assert_eq!(stale.applied, Applied::Stale);
        assert_eq!(stale.snapshot, second.snapshot);
        assert_eq!(
            store.load_state("unseen").await,
            Ok(CircuitSnapshot::default())
        );
    });
}

#[test]
fn one_probe_lease_at_a_time_and_expired_leases_recover() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = store(&clock);
        store
            .record_outcome(
                "a",
                0,
                StoredOutcome::Failure,
                Duration::ZERO,
                failure_policy(1),
            )
            .await
            .expect("opened");
        assert_matches!(
            store.try_begin_probe("a", Duration::from_secs(2)).await,
            Ok(ProbeDecision::Open(_))
        );
        clock.advance(Duration::from_secs(10));
        let decision = store
            .try_begin_probe("a", Duration::from_secs(2))
            .await
            .expect("elected");
        assert_matches!(
            decision,
            ProbeDecision::Acquired {
                transition: Some(StateTransition::HalfOpened),
                ..
            }
        );
        let lease = acquired(decision);
        assert_matches!(
            store.try_begin_probe("a", Duration::from_secs(2)).await,
            Ok(ProbeDecision::Busy(_))
        );
        clock.advance(Duration::from_secs(2));
        let takeover = acquired(
            store
                .try_begin_probe("a", Duration::from_secs(2))
                .await
                .expect("expired lease taken over"),
        );
        let late = store
            .complete_probe(
                "a",
                lease,
                StoredOutcome::Success,
                Duration::ZERO,
                probe_policy(1),
            )
            .await
            .expect("answered");
        assert_eq!(late.applied, Applied::Stale);
        let closed = store
            .complete_probe(
                "a",
                takeover,
                StoredOutcome::Success,
                Duration::ZERO,
                probe_policy(1),
            )
            .await
            .expect("closed");
        assert_eq!(closed.transition, Some(StateTransition::Closed));
        assert_matches!(
            store.try_begin_probe("a", Duration::from_secs(2)).await,
            Ok(ProbeDecision::Closed(_))
        );
    });
}

#[test]
fn a_failed_probe_reopens_and_reset_advances_the_generation() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = store(&clock);
        store
            .record_outcome(
                "a",
                0,
                StoredOutcome::Failure,
                Duration::ZERO,
                failure_policy(1),
            )
            .await
            .expect("opened");
        clock.advance(Duration::from_secs(10));
        let lease = acquired(
            store
                .try_begin_probe("a", Duration::from_secs(2))
                .await
                .expect("elected"),
        );
        let reopened = store
            .complete_probe(
                "a",
                lease,
                StoredOutcome::Failure,
                Duration::ZERO,
                probe_policy(1),
            )
            .await
            .expect("reopened");
        assert_eq!(reopened.transition, Some(StateTransition::Opened));
        assert_eq!(reopened.snapshot.retry_at, Some(Duration::from_secs(20)));
        let reset = store.reset("a").await.expect("reset");
        assert_eq!(reset.state, State::Closed);
        assert!(reset.generation > reopened.snapshot.generation);
    });
}

/// Everything the store keeps for `name`, to prove a refusal changed none of
/// it.
fn kept(store: &MemoryStorage, name: &str) -> (CircuitSnapshot, Option<ProbeLease>, u64, usize) {
    store
        .circuits()
        .get(name)
        .map(|circuit| {
            (
                circuit.snapshot,
                circuit.probe,
                circuit.next_token,
                circuit.events.len(),
            )
        })
        .expect("a seen circuit")
}

fn set(store: &MemoryStorage, name: &str, act: impl FnOnce(&mut MemoryCircuit)) {
    act(store.circuits().entry(String::from(name)).or_default());
}

async fn record(store: &MemoryStorage, generation: u64) -> Result<StorageUpdate, StorageError> {
    store
        .record_outcome(
            "a",
            generation,
            StoredOutcome::Failure,
            Duration::ZERO,
            failure_policy(1),
        )
        .await
}

#[test]
fn an_exhausted_generation_refuses_every_transition_and_changes_nothing() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = store(&clock);
        set(&store, "a", |c| c.snapshot.generation = u64::MAX);

        // Opening would reuse a generation an in-flight call may carry.
        let before = kept(&store, "a");
        assert!(record(&store, u64::MAX).await.is_err());
        assert_eq!(kept(&store, "a"), before, "the outcome was not kept");
        assert!(store.reset("a").await.is_err());
        assert_eq!(kept(&store, "a"), before);

        // Open, cooldown elapsed: half-opening needs a generation.
        set(&store, "a", |c| {
            c.snapshot.generation = u64::MAX - 1;
        });
        record(&store, u64::MAX - 1).await.expect("opened");
        clock.advance(Duration::from_secs(10));
        let before = kept(&store, "a");
        assert_eq!(before.0.generation, u64::MAX, "the last one is used once");
        assert!(
            store
                .try_begin_probe("a", Duration::from_secs(2))
                .await
                .is_err()
        );
        assert_eq!(kept(&store, "a"), before);
    });
}

#[test]
fn an_exhausted_generation_refuses_completing_a_probe_that_transitions() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = store(&clock);
        record(&store, 0).await.expect("opened");
        clock.advance(Duration::from_secs(10));
        let lease = acquired(
            store
                .try_begin_probe("a", Duration::from_secs(2))
                .await
                .expect("elected"),
        );
        set(&store, "a", |c| {
            c.snapshot.generation = u64::MAX;
            c.probe = c.probe.map(|probe| ProbeLease {
                generation: u64::MAX,
                ..probe
            });
        });
        let lease = ProbeLease {
            generation: u64::MAX,
            ..lease
        };
        let before = kept(&store, "a");
        for outcome in [StoredOutcome::Success, StoredOutcome::Failure] {
            assert!(
                store
                    .complete_probe("a", lease, outcome, Duration::ZERO, probe_policy(1))
                    .await
                    .is_err()
            );
            assert_eq!(kept(&store, "a"), before, "{outcome:?} changed nothing");
        }
        // A success below the threshold transitions nothing: honoured.
        let counted = store
            .complete_probe(
                "a",
                lease,
                StoredOutcome::Success,
                Duration::ZERO,
                probe_policy(2),
            )
            .await
            .expect("counted");
        assert_eq!(counted.transition, None);
    });
}

#[test]
fn exhausted_probe_tokens_refuse_and_change_nothing() {
    pollster::block_on(async {
        let clock = ManualClock::default();
        let store = store(&clock);
        record(&store, 0).await.expect("opened");
        clock.advance(Duration::from_secs(10));
        set(&store, "a", |c| c.next_token = u64::MAX - 1);
        let last = acquired(
            store
                .try_begin_probe("a", Duration::from_secs(2))
                .await
                .expect("the last token is issued"),
        );
        assert_eq!(last.token, u64::MAX);
        clock.advance(Duration::from_secs(2));
        let before = kept(&store, "a");
        assert!(
            store
                .try_begin_probe("a", Duration::from_secs(2))
                .await
                .is_err(),
            "a takeover would reuse a token"
        );
        assert_eq!(kept(&store, "a"), before);
    });
}
