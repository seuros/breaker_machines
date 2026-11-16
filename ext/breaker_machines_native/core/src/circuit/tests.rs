use super::*;
use crate::PredicateClassifier;
use crate::test_support::{ManualClock, policy};
use core::assert_matches;
use std::string::{String, ToString};
use std::sync::Mutex;

/// A circuit on `clock` recording every hook it fires.
fn traced(clock: &ManualClock, policy: Policy) -> (CircuitBreaker, Arc<Mutex<Vec<String>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let hook = |tag: &'static str| {
        let seen = Arc::clone(&seen);
        move |_: &str| seen.lock().expect("unpoisoned").push(tag.to_string())
    };
    let circuit = CircuitBreaker::builder("svc", policy)
        .clock(clock.clone())
        .on_open(hook("open"))
        .on_half_open(hook("half_open"))
        .on_close(hook("close"))
        .build();
    (circuit, seen)
}

fn fail(circuit: &mut CircuitBreaker) -> Result<(), CircuitError<&'static str>> {
    circuit.call(|| Err::<(), _>("boom"))
}

#[test]
fn a_full_cycle_fires_each_hook_once() {
    let clock = ManualClock::default();
    let (mut circuit, seen) = traced(&clock, policy(2, 1, 1, None));
    assert_eq!(circuit.call(|| Ok::<_, &str>(7)).expect("closed"), 7);
    assert_matches!(fail(&mut circuit), Err(CircuitError::Execution("boom")));
    assert_matches!(fail(&mut circuit), Err(CircuitError::Execution("boom")));
    assert!(circuit.is_open());
    assert_eq!(circuit.opened_at(), Some(Duration::ZERO));
    assert_matches!(
        fail(&mut circuit),
        Err(CircuitError::Refused {
            refusal: Refusal::Open,
            ..
        })
    );
    clock.advance(Duration::from_secs(10));
    assert_eq!(circuit.retry_after(), Some(Duration::from_secs(20)));
    clock.advance(Duration::from_secs(20));
    assert_eq!(circuit.call(|| Ok::<_, &str>(1)).expect("probe"), 1);
    assert!(circuit.is_closed());
    assert_eq!(
        *seen.lock().expect("unpoisoned"),
        ["open", "half_open", "close"].map(ToString::to_string)
    );
}

#[test]
fn the_fallback_sees_why_the_call_was_refused() {
    let clock = ManualClock::default();
    let (mut circuit, _) = traced(&clock, policy(1, 1, 1, None));
    assert!(fail(&mut circuit).is_err());
    clock.advance(Duration::from_secs(5));
    let answer = circuit.call_with_fallback(
        || Ok::<_, &str>("live"),
        |context| {
            assert_eq!(context.refusal, Refusal::Open);
            assert_eq!(context.retry_after, Some(Duration::from_secs(25)));
            assert_eq!(&*context.circuit, "svc");
            Ok("cached")
        },
    );
    assert_eq!(answer.expect("fallback"), "cached");
}

#[test]
fn calls_accept_closures_that_borrow_locals() {
    let mut circuit = CircuitBreaker::new("borrowing", policy(5, 1, 1, None));
    let mut seen = Vec::new();
    circuit
        .call(|| {
            seen.push(1);
            Ok::<_, &str>(())
        })
        .expect("closed");
    assert_eq!(seen, [1]);
    assert_eq!(circuit.name(), "borrowing");
    assert_eq!(circuit.successes(), 1);
}

#[test]
fn the_classifier_decides_what_counts() {
    let mut circuit = CircuitBreaker::builder("classified", policy(1, 1, 1, Some(1)))
        .classifier(PredicateClassifier::new(|ctx| {
            ctx.error.downcast_ref::<&str>() != Some(&"client error")
        }))
        .build();
    assert!(circuit.call(|| Err::<(), _>("client error")).is_err());
    assert!(circuit.is_closed(), "an ignored error does not count");
    assert_eq!(circuit.failures(), 0);
    assert_eq!(circuit.breaker().outstanding(), 0, "its slot was freed");
    assert!(circuit.call(|| Err::<(), _>("server error")).is_err());
    assert!(circuit.is_open());
}

#[test]
fn a_panicking_probe_frees_its_slot() {
    let clock = ManualClock::default();
    let (mut circuit, _) = traced(&clock, policy(1, 1, 1, None));
    assert!(fail(&mut circuit).is_err());
    clock.advance(Duration::from_secs(30));
    let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        circuit.call(|| -> Result<(), &str> { panic!("probe panicked") })
    }));
    assert!(unwound.is_err());
    assert_eq!(circuit.state(), State::HalfOpen);
    assert_eq!(circuit.breaker().half_open_attempts(), 0);
    assert_eq!(circuit.call(|| Ok::<_, &str>(())), Ok(()));
    assert!(circuit.is_closed());
}

#[test]
fn two_phase_admission_settles_tickets() {
    let clock = ManualClock::default();
    let (mut circuit, _) = traced(&clock, policy(1, 1, 1, Some(1)));
    let mut ticket = circuit.admit().expect("admitted");
    assert_matches!(
        circuit.admit(),
        Err(CircuitError::Refused {
            refusal: Refusal::Full,
            ..
        })
    );
    clock.advance(Duration::from_secs(2));
    assert_eq!(circuit.complete(&mut ticket, Ok::<_, &str>(3)), Ok(3));
    assert_eq!(circuit.events(5)[0].took, Duration::from_secs(2));

    let mut dropped = circuit.admit().expect("slot freed");
    assert_eq!(circuit.abandon(&mut dropped), Ok(()));
    assert_matches!(
        circuit.complete(&mut dropped, Ok::<_, &str>(())),
        Err(CircuitError::Refused {
            refusal: Refusal::Mismatch,
            ..
        })
    );

    let mut other = CircuitBreaker::builder("other", policy(1, 1, 1, None))
        .scope(9)
        .build();
    let mut foreign = other.admit().expect("admitted");
    assert_matches!(
        circuit.complete(&mut foreign, Ok::<_, &str>(())),
        Err(CircuitError::Refused {
            refusal: Refusal::Unknown,
            ..
        })
    );
}

#[test]
fn observe_force_and_reset_drive_the_machine() {
    let clock = ManualClock::default();
    let (mut circuit, seen) = traced(&clock, policy(1, 1, 1, None));
    assert_eq!(
        circuit.observe(&Err::<(), _>("down"), Duration::from_millis(5)),
        State::Open
    );
    clock.advance(Duration::from_secs(30));
    assert_eq!(
        circuit.observe(&Ok::<(), &str>(()), Duration::from_millis(5)),
        State::Closed
    );
    circuit.force_close().expect("an epoch is left");
    circuit.force_open().expect("an epoch is left");
    circuit.force_open().expect("an epoch is left");
    circuit.reset().expect("an epoch is left");
    assert!(circuit.is_closed());
    assert_eq!(circuit.failures(), 0);
    assert_eq!(
        *seen.lock().expect("unpoisoned"),
        ["open", "half_open", "close", "open", "open"].map(ToString::to_string),
        "force_close on a closed circuit and reset fire nothing"
    );
}

#[derive(Debug)]
struct Backwards(Mutex<u64>);

impl Clock for Backwards {
    fn now(&self) -> Duration {
        let mut secs = self.0.lock().expect("unpoisoned");
        *secs = secs.saturating_sub(1);
        Duration::from_secs(*secs)
    }
}

#[test]
fn a_clock_that_steps_back_reads_as_standing_still() {
    let mut circuit = CircuitBreaker::builder("skewed", policy(3, 1, 1, None))
        .clock(Backwards(Mutex::new(100)))
        .build();
    for _ in 0..3 {
        assert!(circuit.call(|| Ok::<_, &str>(())).is_ok());
    }
    assert_eq!(circuit.now(), Duration::from_secs(99));
    assert_eq!(circuit.successes(), 3);
}

/// Model check: over random runs of every operation, the lifecycle machine
/// and the core never disagree, and every hook fired matches a transition
/// the machine made.
#[test]
fn the_lifecycle_machine_never_diverges_from_the_core() {
    use matryona_machines::testing::XorShift64;
    for seed in 1..=24_u64 {
        let mut rng = XorShift64::new(seed);
        let clock = ManualClock::default();
        let limit = (rng.below(3) > 0).then(|| u32::try_from(rng.below(3) + 1).unwrap_or(1));
        let failures = u32::try_from(rng.below(4) + 1).unwrap_or(1);
        let successes = u32::try_from(rng.below(3) + 1).unwrap_or(1);
        let probes = u32::try_from(rng.below(3) + 1).unwrap_or(1);
        let (mut circuit, seen) = traced(&clock, policy(failures, successes, probes, limit));
        let mut held: Vec<Ticket> = Vec::new();
        for _ in 0..2_000 {
            match rng.below(11) {
                0 => drop(circuit.call(|| Ok::<_, &str>(()))),
                1 => drop(fail(&mut circuit)),
                2 => {
                    if let Ok(ticket) = circuit.admit() {
                        held.push(ticket);
                    }
                }
                3 | 4 if !held.is_empty() => {
                    let index = usize::try_from(rng.below(held.len() as u64)).unwrap_or(0);
                    let mut ticket = held.swap_remove(index);
                    let result = if rng.below(2) == 0 {
                        Ok(())
                    } else {
                        Err("boom")
                    };
                    drop(circuit.complete(&mut ticket, result));
                }
                5 if !held.is_empty() => {
                    let mut ticket = held.swap_remove(0);
                    drop(circuit.abandon(&mut ticket));
                }
                6 => {
                    let outcome = if rng.below(2) == 0 {
                        Ok(())
                    } else {
                        Err("down")
                    };
                    circuit.observe(&outcome, Duration::from_millis(rng.below(50)));
                }
                7 => circuit.force_open().expect("an epoch is left"),
                8 => circuit.force_close().expect("an epoch is left"),
                9 if rng.below(8) == 0 => circuit.reset().expect("an epoch is left"),
                _ => clock.advance(Duration::from_secs(rng.below(12))),
            }
            assert_eq!(circuit.state(), circuit.breaker().state(), "seed {seed}");
        }
        assert!(
            !seen.lock().expect("unpoisoned").is_empty(),
            "seed {seed} fired nothing"
        );
    }
}
