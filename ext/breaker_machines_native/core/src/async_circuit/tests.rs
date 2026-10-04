use super::*;
use crate::test_support::poll_once;
use core::assert_matches;
use core::future::{pending, poll_fn};
use core::sync::atomic::{AtomicBool, Ordering};
use core::task::Poll;
use std::sync::Arc;

/// An operation that stays pending until `ready` is set, then succeeds.
fn gated_success(
    ready: &Arc<AtomicBool>,
) -> impl Future<Output = Result<&'static str, &'static str>> + use<> {
    let ready = Arc::clone(ready);
    poll_fn(move |_cx| {
        if ready.load(Ordering::Acquire) {
            Poll::Ready(Ok("stale success"))
        } else {
            Poll::Pending
        }
    })
}

#[test]
fn records_success() {
    pollster::block_on(async {
        let circuit = AsyncCircuitBreaker::builder("test").build_async();

        let result = circuit.call(|| async { Ok::<_, &str>("success") }).await;

        assert_matches!(result, Ok("success"));
        assert!(circuit.is_closed());
    });
}

#[test]
fn opens_after_threshold() {
    pollster::block_on(async {
        let circuit = AsyncCircuitBreaker::builder("test")
            .failure_threshold(2)
            .build_async();

        let _ = circuit.call(|| async { Err::<(), _>("error 1") }).await;
        assert!(circuit.is_closed());

        let _ = circuit.call(|| async { Err::<(), _>("error 2") }).await;
        assert!(circuit.is_open());

        let result = circuit.call(|| async { Ok::<_, &str>("blocked") }).await;
        assert_matches!(result, Err(CircuitError::Open { .. }));
    });
}

#[test]
fn fallback_runs_when_open() {
    pollster::block_on(async {
        let circuit = AsyncCircuitBreaker::builder("test")
            .failure_threshold(1)
            .build_async();
        let _ = circuit.call(|| async { Err::<(), _>("error") }).await;
        assert!(circuit.is_open());

        let result = circuit
            .call_with_options(
                || async { Ok::<String, String>("should not execute".to_string()) },
                AsyncCallOptions::new().with_fallback(|ctx| async move {
                    assert_matches!(
                        ctx,
                        FallbackContext { ref circuit_name, state: "Open", .. }
                            if &**circuit_name == "test"
                    );
                    Ok("fallback response".to_string())
                }),
            )
            .await;

        assert_matches!(result.as_deref(), Ok("fallback response"));
    });
}

#[test]
fn call_with_fallback_future_is_send() {
    fn assert_send<T: Send>(_: T) {}

    let circuit = Arc::new(
        AsyncCircuitBreaker::builder("test")
            .failure_threshold(1)
            .build_async(),
    );
    assert_send(async move {
        circuit
            .call_with_options(
                || async { Ok::<String, String>("success".to_string()) },
                AsyncCallOptions::new().with_fallback(|_ctx| async { Ok("fallback".to_string()) }),
            )
            .await
    });
}

#[test]
fn half_open_limits_in_flight_probes() {
    let circuit = AsyncCircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(0.0)
        .success_threshold(1)
        .build_async();
    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
    assert!(circuit.is_open());

    let mut first = Box::pin(circuit.call(pending::<Result<&'static str, &'static str>>));
    assert_matches!(poll_once(first.as_mut()), Poll::Pending);

    let second = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("second") }));
    assert_matches!(second, Err(CircuitError::HalfOpenLimitReached { .. }));

    // Cancelling the probe frees its slot.
    drop(first);

    let third = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("third") }));
    assert_matches!(third, Ok("third"));
    assert!(circuit.is_closed());
}

#[test]
fn open_fallback_does_not_hold_bulkhead_permit() {
    let circuit = AsyncCircuitBreaker::builder("test")
        .failure_threshold(1)
        .max_concurrency(1)
        .build_async();
    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
    assert!(circuit.is_open());

    let mut fallback = Box::pin(
        circuit.call_with_options(
            || async { Ok::<_, &'static str>("should not execute") },
            AsyncCallOptions::new()
                .with_fallback(|_ctx| pending::<Result<&'static str, &'static str>>()),
        ),
    );
    assert_matches!(poll_once(fallback.as_mut()), Poll::Pending);

    // A parked fallback must not starve the bulkhead: the next call is
    // rejected by the open circuit, not by capacity.
    let result = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("blocked") }));
    assert_matches!(result, Err(CircuitError::Open { .. }));
}

#[test]
fn stale_closed_success_does_not_close_half_open_circuit() {
    let circuit = AsyncCircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(0.0)
        .success_threshold(1)
        .build_async();
    let stale_ready = Arc::new(AtomicBool::new(false));

    // Admitted while Closed; completes after the circuit has moved on.
    let mut stale_call = Box::pin(circuit.call(|| gated_success(&stale_ready)));
    assert_matches!(poll_once(stale_call.as_mut()), Poll::Pending);

    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
    assert!(circuit.is_open());

    let mut current_probe = Box::pin(circuit.call(pending::<Result<(), &'static str>>));
    assert_matches!(poll_once(current_probe.as_mut()), Poll::Pending);
    assert_eq!(circuit.state_name(), "HalfOpen");

    stale_ready.store(true, Ordering::Release);
    assert_matches!(
        poll_once(stale_call.as_mut()),
        Poll::Ready(Ok("stale success"))
    );
    assert_eq!(circuit.state_name(), "HalfOpen");

    drop(current_probe);
    let result = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("current") }));
    assert_matches!(result, Ok("current"));
    assert!(circuit.is_closed());
}

#[test]
fn stale_half_open_probe_does_not_affect_new_half_open_generation() {
    let circuit = AsyncCircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(0.0)
        .success_threshold(2)
        .build_async();
    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("initial error") }));
    assert!(circuit.is_open());

    let stale_ready = Arc::new(AtomicBool::new(false));
    let mut stale_probe = Box::pin(circuit.call(|| gated_success(&stale_ready)));
    assert_matches!(poll_once(stale_probe.as_mut()), Poll::Pending);

    // A failing probe reopens; the next call starts a new HalfOpen generation.
    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("probe error") }));
    assert!(circuit.is_open());

    let mut current_probe = Box::pin(circuit.call(pending::<Result<(), &'static str>>));
    assert_matches!(poll_once(current_probe.as_mut()), Poll::Pending);
    assert_eq!(circuit.state_name(), "HalfOpen");

    stale_ready.store(true, Ordering::Release);
    assert_matches!(
        poll_once(stale_probe.as_mut()),
        Poll::Ready(Ok("stale success"))
    );
    drop(current_probe);

    let first = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("first") }));
    assert_matches!(first, Ok("first"));
    assert_eq!(circuit.state_name(), "HalfOpen");

    let second = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("second") }));
    assert_matches!(second, Ok("second"));
    assert!(circuit.is_closed());
}

#[test]
fn reset_fences_probes_from_before_the_reset() {
    let circuit = AsyncCircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(0.0)
        .success_threshold(1)
        .build_async();
    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));

    let stale_ready = Arc::new(AtomicBool::new(false));
    let mut stale_probe = Box::pin(circuit.call(|| gated_success(&stale_ready)));
    assert_matches!(poll_once(stale_probe.as_mut()), Poll::Pending);

    // Walk the same Closed -> Open -> HalfOpen path again after a reset, so a
    // per-machine counter restarted by the reset would collide with the stale
    // probe's epoch.
    circuit.reset();
    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
    let mut current_probe = Box::pin(circuit.call(pending::<Result<(), &'static str>>));
    assert_matches!(poll_once(current_probe.as_mut()), Poll::Pending);

    stale_ready.store(true, Ordering::Release);
    assert_matches!(
        poll_once(stale_probe.as_mut()),
        Poll::Ready(Ok("stale success"))
    );

    // The stale success neither closed the circuit nor freed the live slot.
    assert_eq!(circuit.state_name(), "HalfOpen");
    let competing = pollster::block_on(circuit.call(|| async { Ok::<_, &str>(()) }));
    assert_matches!(competing, Err(CircuitError::HalfOpenLimitReached { .. }));
}
