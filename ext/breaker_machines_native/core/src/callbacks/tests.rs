use super::*;
use std::string::{String, ToString};
use std::sync::Mutex;

#[test]
fn each_transition_fires_its_hook_with_the_name() {
    let seen = Arc::new(Mutex::new(std::vec::Vec::<String>::new()));
    let hook = |tag: &'static str| -> CallbackFn {
        let seen = Arc::clone(&seen);
        Arc::new(move |name| {
            seen.lock()
                .expect("unpoisoned")
                .push(std::format!("{tag}:{name}"));
        })
    };
    let callbacks = Callbacks {
        on_open: Some(hook("open")),
        on_close: Some(hook("close")),
        on_half_open: Some(hook("half_open")),
    };
    callbacks.fire(Transition::Opened, "a");
    callbacks.fire(Transition::HalfOpened, "b");
    callbacks.fire(Transition::Closed, "c");
    assert_eq!(
        *seen.lock().expect("unpoisoned"),
        ["open:a", "half_open:b", "close:c"].map(ToString::to_string)
    );
}

#[test]
fn a_panicking_hook_is_contained() {
    let callbacks = Callbacks {
        on_open: Some(Arc::new(|_| panic!("intentional panic in on_open"))),
        ..Callbacks::default()
    };
    callbacks.fire(Transition::Opened, "test");
    callbacks.fire(Transition::Closed, "no hook set");
    assert_eq!(
        std::format!("{callbacks:?}"),
        "Callbacks { on_open: true, on_close: false, on_half_open: false }"
    );
}
