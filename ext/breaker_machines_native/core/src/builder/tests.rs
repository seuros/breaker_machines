use super::*;

#[test]
fn test_builder_defaults() {
    let circuit = CircuitBuilder::new("test").build();

    assert_eq!(circuit.state_name(), "Closed");
    assert!(circuit.is_closed());
}

#[test]
fn test_builder_custom_config() {
    let circuit = CircuitBuilder::new("test")
        .failure_threshold(10)
        .failure_window_secs(120.0)
        .half_open_timeout_secs(60.0)
        .success_threshold(3)
        .build();

    assert!(circuit.is_closed());
}

#[test]
fn test_builder_with_callbacks() {
    use std::sync::atomic::{AtomicBool, Ordering};

    let opened = Arc::new(AtomicBool::new(false));
    let opened_clone = opened.clone();

    let mut circuit = CircuitBuilder::new("test")
        .failure_threshold(2)
        .on_open(move |_name| {
            opened_clone.store(true, Ordering::SeqCst);
        })
        .build();

    // Trigger failures to open circuit
    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));

    // Callback should have been triggered
    assert!(opened.load(Ordering::SeqCst));
}
