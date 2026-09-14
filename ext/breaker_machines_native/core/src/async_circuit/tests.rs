use super::*;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

fn poll_once<F: Future>(future: Pin<&mut F>) -> std::task::Poll<F::Output> {
    let waker = std::task::Waker::noop();
    let mut context = std::task::Context::from_waker(waker);
    std::future::Future::poll(future, &mut context)
}

#[test]
fn async_call_records_success() {
    pollster::block_on(async {
        let circuit = AsyncCircuitBreaker::builder("test").build_async();

        let result = circuit.call(|| async { Ok::<_, String>("success") }).await;

        assert_eq!(result.unwrap(), "success");
        assert!(circuit.is_closed());
    });
}

#[test]
fn async_call_opens_after_threshold() {
    pollster::block_on(async {
        let circuit = AsyncCircuitBreaker::builder("test")
            .failure_threshold(2)
            .build_async();

        let _ = circuit.call(|| async { Err::<(), _>("error 1") }).await;
        assert!(circuit.is_closed());

        let _ = circuit.call(|| async { Err::<(), _>("error 2") }).await;
        assert!(circuit.is_open());

        let result = circuit.call(|| async { Ok::<_, &str>("blocked") }).await;
        assert!(matches!(result, Err(CircuitError::Open { .. })));
    });
}

#[test]
fn async_fallback_runs_when_open() {
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
                    assert_eq!(ctx.circuit_name, "test");
                    assert_eq!(ctx.state, "Open");
                    Ok("fallback response".to_string())
                }),
            )
            .await;

        assert_eq!(result.unwrap(), "fallback response");
    });
}

#[test]
fn async_call_with_fallback_future_is_send() {
    fn assert_send<T: Send>(_: T) {}

    let circuit = std::sync::Arc::new(
        AsyncCircuitBreaker::builder("test")
            .failure_threshold(1)
            .build_async(),
    );
    let future = async move {
        circuit
            .call_with_options(
                || async { Ok::<String, String>("success".to_string()) },
                AsyncCallOptions::new().with_fallback(|_ctx| async { Ok("fallback".to_string()) }),
            )
            .await
    };

    assert_send(future);
}

#[test]
fn async_half_open_limits_in_flight_probes() {
    let circuit = AsyncCircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(0.0)
        .success_threshold(1)
        .build_async();

    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
    assert!(circuit.is_open());

    let mut first =
        Box::pin(circuit.call(std::future::pending::<Result<&'static str, &'static str>>));
    assert!(matches!(
        poll_once(first.as_mut()),
        std::task::Poll::Pending
    ));

    let second = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("second") }));
    assert!(matches!(
        second,
        Err(CircuitError::HalfOpenLimitReached { .. })
    ));

    drop(first);

    let third = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("third") }));
    assert_eq!(third.unwrap(), "third");
    assert!(circuit.is_closed());
}

#[test]
fn async_open_fallback_does_not_hold_bulkhead_permit() {
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
                .with_fallback(|_ctx| std::future::pending::<Result<&'static str, &'static str>>()),
        ),
    );
    assert!(matches!(
        poll_once(fallback.as_mut()),
        std::task::Poll::Pending
    ));

    let result = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("blocked") }));
    assert!(matches!(result, Err(CircuitError::Open { .. })));

    drop(fallback);
}

#[test]
fn stale_closed_success_does_not_close_half_open_circuit() {
    let circuit = AsyncCircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(0.0)
        .success_threshold(1)
        .build_async();
    let stale_ready = Arc::new(AtomicBool::new(false));
    let operation_ready = Arc::clone(&stale_ready);
    let mut stale_call = Box::pin(circuit.call(move || async move {
        std::future::poll_fn(move |_context| {
            if operation_ready.load(Ordering::Acquire) {
                std::task::Poll::Ready(Ok::<_, &'static str>("stale success"))
            } else {
                std::task::Poll::Pending
            }
        })
        .await
    }));

    assert!(matches!(
        poll_once(stale_call.as_mut()),
        std::task::Poll::Pending
    ));

    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("error") }));
    assert!(circuit.is_open());

    let mut current_probe =
        Box::pin(circuit.call(std::future::pending::<Result<(), &'static str>>));
    assert!(matches!(
        poll_once(current_probe.as_mut()),
        std::task::Poll::Pending
    ));
    assert_eq!(circuit.state_name(), "HalfOpen");

    stale_ready.store(true, Ordering::Release);
    assert!(matches!(
        poll_once(stale_call.as_mut()),
        std::task::Poll::Ready(Ok("stale success"))
    ));
    assert_eq!(circuit.state_name(), "HalfOpen");

    drop(current_probe);
    let result = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("current") }));
    assert_eq!(result.unwrap(), "current");
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
    let operation_ready = Arc::clone(&stale_ready);
    let mut stale_probe = Box::pin(circuit.call(move || async move {
        std::future::poll_fn(move |_context| {
            if operation_ready.load(Ordering::Acquire) {
                std::task::Poll::Ready(Ok::<_, &'static str>("stale success"))
            } else {
                std::task::Poll::Pending
            }
        })
        .await
    }));
    assert!(matches!(
        poll_once(stale_probe.as_mut()),
        std::task::Poll::Pending
    ));

    let _ = pollster::block_on(circuit.call(|| async { Err::<(), _>("probe error") }));
    assert!(circuit.is_open());

    let mut current_probe =
        Box::pin(circuit.call(std::future::pending::<Result<(), &'static str>>));
    assert!(matches!(
        poll_once(current_probe.as_mut()),
        std::task::Poll::Pending
    ));
    assert_eq!(circuit.state_name(), "HalfOpen");

    stale_ready.store(true, Ordering::Release);
    assert!(matches!(
        poll_once(stale_probe.as_mut()),
        std::task::Poll::Ready(Ok("stale success"))
    ));
    drop(current_probe);

    let first = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("first") }));
    assert_eq!(first.unwrap(), "first");
    assert_eq!(circuit.state_name(), "HalfOpen");

    let second = pollster::block_on(circuit.call(|| async { Ok::<_, &str>("second") }));
    assert_eq!(second.unwrap(), "second");
    assert!(circuit.is_closed());
}
