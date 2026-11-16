use crate::breaker::tests::{opened, policy, secs};
use crate::{
    Adopted, Breaker, Completed, ForceClosed, Observed, Outcome, Refusal, Settled, Status,
};
use matryona_machines::testing::{refuses, unchanged};

/// `breaker` with its transition epoch at the last value it can hold.
fn at_last_epoch(mut breaker: Breaker<16>) -> Breaker<16> {
    breaker.epoch = u64::MAX;
    breaker
}

#[test]
fn an_exhausted_epoch_refuses_every_transition_and_changes_nothing() {
    // A transition would reuse an epoch an outstanding ticket may carry, so
    // every call that would transition is refused instead.
    let mut breaker = at_last_epoch(opened(secs(0)));
    refuses(&mut breaker, Refusal::Exhausted, |b| b.admit(secs(30)));
    refuses(&mut breaker, Refusal::Exhausted, |b| {
        b.force_open(secs(1), 0)
    });
    refuses(&mut breaker, Refusal::Exhausted, |b| {
        b.observe(Outcome::Success, secs(0), secs(30), 0)
    });

    let mut closed = at_last_epoch(Breaker::new(policy(1, 0.0, 1, 1)));
    let mut ticket = closed
        .admit(secs(0))
        .expect("a call opens nothing")
        .into_ticket();
    refuses(&mut closed, Refusal::Exhausted, |b| {
        b.complete(&mut ticket, Outcome::Failure, secs(1), 0)
    });
    assert_eq!(ticket.settled(), None, "the refused ticket stays unsettled");
    refuses(&mut closed, Refusal::Exhausted, |b| {
        b.observe(Outcome::Failure, secs(0), secs(1), 0)
    });
}

#[test]
fn an_exhausted_epoch_still_honours_what_does_not_transition() {
    let mut breaker = at_last_epoch(Breaker::new(policy(3, 0.0, 1, 1)));
    let mut ticket = breaker.admit(secs(0)).expect("call").into_ticket();
    assert_eq!(
        breaker.complete(&mut ticket, Outcome::Failure, secs(1), 0),
        Ok(Completed::Settled(Settled::Counted))
    );
    assert_eq!(
        breaker.observe(Outcome::Success, secs(0), secs(1), 0),
        Ok(Observed::Settled(Settled::Counted))
    );
    assert_eq!(breaker.epoch, u64::MAX);
}

#[test]
fn the_last_epoch_is_used_once() {
    let mut breaker = Breaker::<16>::new(policy(1, 0.0, 1, 1));
    breaker.epoch = u64::MAX - 1;
    breaker.force_open(secs(0), 0).expect("one epoch is left");
    assert_eq!(breaker.epoch, u64::MAX);
    refuses(&mut breaker, Refusal::Exhausted, |b| {
        b.force_open(secs(1), 0)
    });
}

#[test]
fn an_exhausted_epoch_refuses_force_close_reset_and_adopt() {
    let mut breaker = at_last_epoch(opened(secs(0)));
    refuses(&mut breaker, Refusal::Exhausted, Breaker::force_close);
    refuses(&mut breaker, Refusal::Exhausted, Breaker::reset);
    let closed = Status::closed();
    refuses(&mut breaker, Refusal::Exhausted, |b| b.adopt(closed));
    let open = breaker.status();
    unchanged(&mut breaker, |b| {
        assert_eq!(b.adopt(open), Ok(Adopted::Unchanged));
    });

    let mut closed_breaker = at_last_epoch(Breaker::new(policy(3, 0.0, 1, 1)));
    unchanged(&mut closed_breaker, |b| {
        assert_eq!(b.force_close(), Ok(ForceClosed::AlreadyClosed));
    });
}

#[test]
fn the_threshold_is_judged_on_the_ring_as_it_will_be() {
    // Two kept outcomes, two failures open it: the failure that would make
    // a second one also pushes the first failure out of the ring.
    let mut breaker = Breaker::<2>::new(policy(2, 0.0, 1, 1));
    for outcome in [Outcome::Failure, Outcome::Success] {
        let mut ticket = breaker.admit(secs(0)).expect("call").into_ticket();
        breaker
            .complete(&mut ticket, outcome, secs(0), 0)
            .expect("counted");
    }
    let mut ticket = breaker.admit(secs(0)).expect("call").into_ticket();
    assert_eq!(
        breaker.complete(&mut ticket, Outcome::Failure, secs(0), 0),
        Ok(Completed::Settled(Settled::Counted))
    );
    let mut ticket = breaker.admit(secs(0)).expect("call").into_ticket();
    assert_eq!(
        breaker.complete(&mut ticket, Outcome::Failure, secs(0), 0),
        Ok(Completed::Settled(Settled::Opened))
    );
}
