use super::*;
use core::assert_matches;
use core::sync::atomic::{AtomicBool, Ordering};

#[test]
fn defaults_build_a_closed_circuit() {
    let circuit = CircuitBuilder::new("test").build();

    assert_eq!(circuit.state_name(), "Closed");
    assert!(circuit.is_closed());
}

#[test]
fn setters_shape_the_config() {
    let builder = CircuitBuilder::new("test")
        .failure_threshold(10)
        .failure_window_secs(120.0)
        .half_open_timeout_secs(60.0)
        .success_threshold(3)
        .failure_rate(1.5)
        .minimum_calls(7);

    assert_matches!(
        builder.config,
        Config {
            failure_threshold: Some(10),
            failure_window_secs: 120.0,
            half_open_timeout_secs: 60.0,
            success_threshold: 3,
            failure_rate_threshold: Some(1.0), // clamped to [0.0, 1.0]
            minimum_calls: 7,
            ..
        }
    );
    assert!(builder.build().is_closed());
}

#[test]
fn disable_failure_threshold_leaves_rate_only() {
    let builder = CircuitBuilder::new("test")
        .failure_threshold(10)
        .disable_failure_threshold();

    assert_matches!(
        builder.config,
        Config {
            failure_threshold: None,
            ..
        }
    );
}

#[test]
fn on_open_callback_fires_when_tripped() {
    let opened = Arc::new(AtomicBool::new(false));
    let on_open = Arc::clone(&opened);
    let mut circuit = CircuitBuilder::new("test")
        .failure_threshold(2)
        .on_open(move |_name| on_open.store(true, Ordering::SeqCst))
        .build();

    let _ = circuit.call(|| Err::<(), _>("error 1"));
    assert!(!opened.load(Ordering::SeqCst));

    let _ = circuit.call(|| Err::<(), _>("error 2"));
    assert!(opened.load(Ordering::SeqCst));
}
