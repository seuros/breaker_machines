use super::*;
use crate::Refusal;
use crate::test_support::{ManualClock, policy, poll_once};
use core::assert_matches;
use core::future::pending;
use core::pin::pin;
use core::task::Poll;
use std::boxed::Box;

fn circuit(clock: &ManualClock, failures: u32, limit: Option<u32>) -> AsyncCircuitBreaker {
    AsyncCircuitBreaker::builder("async", policy(failures, 1, 1, limit))
        .clock(clock.clone())
        .build_async()
}

fn fail(circuit: &AsyncCircuitBreaker) {
    let result = pollster::block_on(circuit.call(|| async { Err::<(), _>("boom") }));
    assert_matches!(
        result,
        Err(CircuitError::Execution("boom") | CircuitError::Refused { .. })
    );
}

#[test]
fn calls_open_the_circuit_and_fallbacks_replace_refusals() {
    let clock = ManualClock::default();
    let circuit = circuit(&clock, 2, None);
    let ok = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("up") }));
    assert_matches!(ok, Ok("up"));
    fail(&circuit);
    fail(&circuit);
    assert!(circuit.is_open());
    let answer = pollster::block_on(circuit.call_with_fallback(
        || async { Ok::<_, &str>("live") },
        |context| async move {
            assert_eq!(context.refusal, Refusal::Open);
            Ok("cached")
        },
    ));
    assert_matches!(answer, Ok("cached"));
    clock.advance(Duration::from_secs(30));
    assert_eq!(circuit.retry_after(), Some(Duration::ZERO));
    assert_matches!(
        pollster::block_on(circuit.call(|| async { Ok::<_, &str>(()) })),
        Ok(())
    );
    assert!(circuit.is_closed());
    assert_eq!(circuit.name(), "async");
}

#[test]
fn a_cancelled_call_frees_its_slots() {
    let clock = ManualClock::default();
    let circuit = circuit(&clock, 1, Some(1));
    {
        let mut parked = Box::pin(circuit.call(pending::<Result<(), &str>>));
        assert_matches!(poll_once(parked.as_mut()), Poll::Pending);
        assert_matches!(
            circuit.admit(),
            Err(CircuitError::Refused {
                refusal: Refusal::Full,
                ..
            })
        );
    }
    assert_eq!(circuit.breaker().outstanding(), 0);

    fail(&circuit);
    clock.advance(Duration::from_secs(30));
    let probe = circuit.admit().expect("probe");
    assert_eq!(circuit.state(), State::HalfOpen);
    drop(probe);
    assert_eq!(circuit.breaker().half_open_attempts(), 0);
    let probe = circuit.admit().expect("the slot came back");
    assert_eq!(probe.complete(Ok::<_, &str>(4)), Ok(4));
    assert!(circuit.is_closed());
}

#[test]
fn a_stale_call_cannot_close_a_newer_visit() {
    let clock = ManualClock::default();
    let circuit = circuit(&clock, 1, None);
    let old = circuit.admit().expect("closed call");
    circuit.force_open().expect("an epoch is left");
    clock.advance(Duration::from_secs(30));
    let probe = circuit.admit().expect("probe");
    assert_eq!(old.complete(Ok::<_, &str>(())), Ok(()));
    assert_eq!(
        circuit.state(),
        State::HalfOpen,
        "the stale success counts only"
    );
    probe.abandon();
    circuit.force_close().expect("an epoch is left");
    assert!(circuit.is_closed());
    circuit.reset().expect("an epoch is left");
    assert_eq!(circuit.opened_at(), None);
}

#[test]
fn observe_drives_the_circuit() {
    let clock = ManualClock::default();
    let circuit = circuit(&clock, 1, None);
    assert_eq!(
        circuit.observe(&Err::<(), _>("down"), Duration::ZERO),
        State::Open
    );
    assert_eq!(circuit.opened_at(), Some(Duration::ZERO));
}

#[test]
fn futures_and_tickets_are_send() {
    const fn assert_send<T: Send>(_: &T) {}
    let clock = ManualClock::default();
    let circuit = circuit(&clock, 1, None);
    let call = pin!(circuit.call(|| async { Ok::<_, &str>(()) }));
    assert_send(&call);
    let ticket = circuit.admit().expect("admitted");
    assert_send(&ticket);
    assert_eq!(ticket.admitted_at(), Duration::ZERO);
}
