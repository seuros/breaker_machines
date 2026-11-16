//! The runtime's lifecycle machine: the circuit's closed, open and
//! half-open states on `state-machines`, moved only by the core's answers.
//!
//! The machine has no guards. It never decides; the [`Breaker`](crate::Breaker)
//! does, and every honoured transition it answers is replayed here, so the
//! two always agree (`circuit::tests` checks it over random runs).

use crate::{Settled, State};
use state_machines::state_machine;

state_machine! {
    name: Lifecycle,
    dynamic: true,
    initial: Closed,
    states: [Closed, Open, HalfOpen],
    events {
        trip { transition: { from: Closed, to: Open } }
        reopen { transition: { from: HalfOpen, to: Open } }
        attempt_recovery { transition: { from: Open, to: HalfOpen } }
        close { transition: { from: HalfOpen, to: Closed } }
        force_open { transition: { from: [Closed, Open, HalfOpen], to: Open } }
        force_close { transition: { from: [Open, HalfOpen], to: Closed } }
        reset { transition: { from: [Closed, Open, HalfOpen], to: Closed } }
    }
}

/// The machine's state as the core names it.
pub const fn state_of(state: LifecycleState) -> State {
    match state {
        LifecycleState::Closed => State::Closed,
        LifecycleState::Open => State::Open,
        LifecycleState::HalfOpen => State::HalfOpen,
    }
}

/// The event replaying a settlement the core answered from `before`.
pub const fn settled_event(before: State, settled: Settled) -> Option<LifecycleEvent> {
    match (settled, before) {
        (Settled::Counted, _) => None,
        (Settled::Opened, State::HalfOpen) => Some(LifecycleEvent::Reopen),
        (Settled::Opened, State::Closed | State::Open) => Some(LifecycleEvent::Trip),
        (Settled::Closed, _) => Some(LifecycleEvent::Close),
    }
}
