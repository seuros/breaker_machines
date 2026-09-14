use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

#[test]
fn test_callback_panic_safety() {
    // Callbacks that panic should not crash the program
    let callbacks = Callbacks {
        on_open: Some(Arc::new(|_| panic!("intentional panic in on_open"))),
        on_close: Some(Arc::new(|_| panic!("intentional panic in on_close"))),
        on_half_open: Some(Arc::new(|_| panic!("intentional panic in on_half_open"))),
    };

    // These should not panic - the panics are caught internally
    callbacks.trigger_open("test");
    callbacks.trigger_close("test");
    callbacks.trigger_half_open("test");
}

#[test]
fn test_callback_executes_successfully() {
    let open_called = Arc::new(AtomicBool::new(false));
    let close_called = Arc::new(AtomicBool::new(false));
    let half_open_called = Arc::new(AtomicBool::new(false));

    let open_clone = open_called.clone();
    let close_clone = close_called.clone();
    let half_open_clone = half_open_called.clone();

    let callbacks = Callbacks {
        on_open: Some(Arc::new(move |_| {
            open_clone.store(true, Ordering::SeqCst);
        })),
        on_close: Some(Arc::new(move |_| {
            close_clone.store(true, Ordering::SeqCst);
        })),
        on_half_open: Some(Arc::new(move |_| {
            half_open_clone.store(true, Ordering::SeqCst);
        })),
    };

    callbacks.trigger_open("test");
    callbacks.trigger_close("test");
    callbacks.trigger_half_open("test");

    assert!(
        open_called.load(Ordering::SeqCst),
        "on_open should be called"
    );
    assert!(
        close_called.load(Ordering::SeqCst),
        "on_close should be called"
    );
    assert!(
        half_open_called.load(Ordering::SeqCst),
        "on_half_open should be called"
    );
}

#[test]
fn test_callback_receives_circuit_name() {
    let received_name = Arc::new(std::sync::Mutex::new(String::new()));
    let name_clone = received_name.clone();

    let callbacks = Callbacks {
        on_open: Some(Arc::new(move |name| {
            *name_clone.lock().unwrap() = name.to_string();
        })),
        on_close: None,
        on_half_open: None,
    };

    callbacks.trigger_open("my_circuit");

    assert_eq!(*received_name.lock().unwrap(), "my_circuit");
}
