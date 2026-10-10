use super::*;
use alloc::string::{String, ToString};
use core::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

fn flag() -> (Arc<AtomicBool>, CallbackFn) {
    let called = Arc::new(AtomicBool::new(false));
    let setter = Arc::clone(&called);
    (
        called,
        Arc::new(move |_| setter.store(true, Ordering::SeqCst)),
    )
}

#[test]
#[cfg(feature = "std")]
fn panicking_callbacks_are_contained() {
    let callbacks = Callbacks {
        on_open: Some(Arc::new(|_| panic!("intentional panic in on_open"))),
        on_close: Some(Arc::new(|_| panic!("intentional panic in on_close"))),
        on_half_open: Some(Arc::new(|_| panic!("intentional panic in on_half_open"))),
    };

    // Panics are caught so they never unwind across the FFI boundary.
    callbacks.trigger_open("test");
    callbacks.trigger_close("test");
    callbacks.trigger_half_open("test");
}

#[test]
#[cfg(not(feature = "std"))]
#[should_panic(expected = "intentional panic in on_open")]
fn panicking_callbacks_propagate_without_std() {
    let callbacks = Callbacks {
        on_open: Some(Arc::new(|_| panic!("intentional panic in on_open"))),
        ..Callbacks::new()
    };

    // Without `std` there is no `catch_unwind` to contain it.
    callbacks.trigger_open("test");
}

#[test]
fn each_trigger_runs_its_callback() {
    let (opened, on_open) = flag();
    let (closed, on_close) = flag();
    let (half_opened, on_half_open) = flag();
    let callbacks = Callbacks {
        on_open: Some(on_open),
        on_close: Some(on_close),
        on_half_open: Some(on_half_open),
    };

    callbacks.trigger_open("test");
    assert!(opened.load(Ordering::SeqCst), "on_open not called");
    assert!(!closed.load(Ordering::SeqCst), "on_close called early");

    callbacks.trigger_close("test");
    callbacks.trigger_half_open("test");
    assert!(closed.load(Ordering::SeqCst), "on_close not called");
    assert!(
        half_opened.load(Ordering::SeqCst),
        "on_half_open not called"
    );
}

#[test]
fn callback_receives_circuit_name() {
    let received = Arc::new(Mutex::new(String::new()));
    let sink = Arc::clone(&received);
    let callbacks = Callbacks {
        on_open: Some(Arc::new(move |name| {
            *sink.lock().unwrap() = name.to_string();
        })),
        ..Callbacks::new()
    };

    callbacks.trigger_open("my_circuit");

    assert_eq!(*received.lock().unwrap(), "my_circuit");
}
