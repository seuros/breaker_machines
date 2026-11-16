use super::*;
use crate::{Recovery, Settled, Threshold};
use core::assert_matches;
use core::num::NonZeroU32;
use matryona_machines::testing::{refuses, unchanged};

pub const fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

fn nz(n: u32) -> NonZeroU32 {
    NonZeroU32::new(n).expect("test counts are positive")
}

/// `failures` in a 60 s window open it; 30 s cooldown with `jitter`;
/// `successes` probes close it, `probes` at a time.
pub fn policy(failures: u32, jitter: f64, successes: u32, probes: u32) -> Policy {
    Policy::new(
        Threshold::new(Some(nz(failures)), None, 0).expect("valid"),
        secs(60),
        Recovery::new(secs(30), jitter, nz(successes), nz(probes)).expect("valid"),
        None,
    )
    .expect("valid")
}

fn call(breaker: &mut Breaker<16>, outcome: Outcome, now: Duration) -> Settled {
    let mut ticket = breaker.admit(now).expect("admitted").into_ticket();
    match breaker.complete(&mut ticket, outcome, now, 0) {
        Ok(Completed::Settled(settled)) => settled,
        other => panic!("expected a fresh settlement, got {other:?}"),
    }
}

/// Three failures at `at` open it; retry from `at + 30`.
pub fn opened(at: Duration) -> Breaker<16> {
    let mut breaker = Breaker::new(policy(3, 0.0, 2, 1));
    assert_eq!(call(&mut breaker, Outcome::Failure, at), Settled::Counted);
    assert_eq!(call(&mut breaker, Outcome::Failure, at), Settled::Counted);
    assert_eq!(call(&mut breaker, Outcome::Failure, at), Settled::Opened);
    breaker
}

#[test]
fn closed_admits_calls_and_counts_outcomes() {
    let mut breaker = Breaker::<16>::new(policy(3, 0.0, 2, 1));
    assert_eq!(breaker.state(), State::Closed);
    let admitted = breaker.admit(secs(1)).expect("admitted");
    assert_matches!(&admitted, Admitted::Call(ticket) if ticket.kind() == Kind::Call);
    let mut ticket = admitted.into_ticket();
    assert_eq!(ticket.admitted_at(), secs(1));
    assert_eq!(breaker.outstanding(), 1);
    assert_eq!(
        breaker.complete(&mut ticket, Outcome::Success, secs(3), 0),
        Ok(Completed::Settled(Settled::Counted))
    );
    assert_eq!(breaker.outstanding(), 0);
    assert_eq!(breaker.successes(secs(3)), 1);
    let mut out = [Event::default(); 4];
    assert_eq!(breaker.events(&mut out), 1);
    assert_eq!(
        out[0],
        Event {
            at: secs(3),
            outcome: Outcome::Success,
            took: secs(2)
        }
    );
}

#[test]
fn threshold_opens_and_cooldown_refuses_until_due() {
    let mut breaker = opened(secs(10));
    assert_eq!(breaker.state(), State::Open);
    assert_eq!(breaker.opened_at(), Some(secs(10)));
    assert_eq!(breaker.retry_at(), Some(secs(40)));
    assert_eq!(breaker.retry_after(secs(25)), Some(secs(15)));
    assert_eq!(breaker.retry_after(secs(99)), Some(Duration::ZERO));
    refuses(&mut breaker, Refusal::Open, |b| b.admit(secs(39)));

    let admitted = breaker.admit(secs(40)).expect("cooldown elapsed");
    assert_matches!(&admitted, Admitted::HalfOpened(ticket) if ticket.kind() == Kind::Probe);
    assert_eq!(breaker.state(), State::HalfOpen);
    assert_eq!(breaker.half_open_attempts(), 1);
    refuses(&mut breaker, Refusal::Busy, |b| b.admit(secs(41)));
    drop(admitted);
}

#[test]
fn probes_close_and_the_window_starts_fresh() {
    let mut breaker = opened(secs(0));
    let mut first = breaker.admit(secs(30)).expect("probe").into_ticket();
    assert_eq!(
        breaker.complete(&mut first, Outcome::Success, secs(31), 0),
        Ok(Completed::Settled(Settled::Counted))
    );
    assert_eq!(breaker.half_open_successes(), 1);
    assert_eq!(breaker.half_open_attempts(), 1);
    let second = breaker.admit(secs(31)).expect("slot freed");
    assert_matches!(second, Admitted::Probe(_));
    assert_eq!(
        breaker.complete(&mut second.into_ticket(), Outcome::Success, secs(32), 0),
        Ok(Completed::Settled(Settled::Closed))
    );
    assert_eq!(breaker.state(), State::Closed);
    // The three failures at 0 are still inside a 60 s window at 33; they
    // must not reopen the circuit on the first failure after recovery.
    assert_eq!(
        call(&mut breaker, Outcome::Failure, secs(33)),
        Settled::Counted
    );
    assert_eq!(breaker.failures(secs(33)), 1);
}

#[test]
fn a_failed_probe_reopens_with_a_fresh_cooldown() {
    let mut breaker = opened(secs(0));
    let mut probe = breaker.admit(secs(30)).expect("probe").into_ticket();
    assert_eq!(
        breaker.complete(&mut probe, Outcome::Failure, secs(35), 0),
        Ok(Completed::Settled(Settled::Opened))
    );
    assert_eq!(breaker.opened_at(), Some(secs(35)));
    assert_eq!(breaker.retry_at(), Some(secs(65)));
}

#[test]
fn a_stale_ticket_counts_but_drives_nothing() {
    let mut breaker = Breaker::<16>::new(policy(1, 0.0, 1, 1));
    let mut old = breaker.admit(secs(0)).expect("call").into_ticket();
    breaker.force_open(secs(1), 0).expect("forced");
    assert_eq!(
        breaker.complete(&mut old, Outcome::Failure, secs(2), 0),
        Ok(Completed::Settled(Settled::Counted))
    );
    assert_eq!(breaker.retry_at(), Some(secs(31)), "no new cooldown");
    assert_eq!(breaker.failures(secs(2)), 1);

    // A probe from an ended half-open visit frees nothing of the next one.
    let mut probe = breaker.admit(secs(31)).expect("probe").into_ticket();
    breaker.force_open(secs(32), 0).expect("forced");
    let mut fresh = breaker.admit(secs(62)).expect("probe").into_ticket();
    assert_eq!(
        breaker.complete(&mut probe, Outcome::Success, secs(63), 0),
        Ok(Completed::Settled(Settled::Counted))
    );
    assert_eq!(breaker.state(), State::HalfOpen);
    assert_eq!(
        breaker.half_open_attempts(),
        1,
        "the fresh probe still runs"
    );
    refuses(&mut breaker, Refusal::Busy, |b| b.admit(secs(63)));
    assert_eq!(
        breaker.complete(&mut fresh, Outcome::Success, secs(64), 0),
        Ok(Completed::Settled(Settled::Closed))
    );
}

#[test]
fn abandon_frees_slots_without_recording() {
    let mut breaker = opened(secs(0));
    let mut probe = breaker.admit(secs(30)).expect("probe").into_ticket();
    assert_eq!(breaker.abandon(&mut probe), Ok(Abandoned::Released));
    assert_eq!(breaker.half_open_attempts(), 0);
    assert_eq!(breaker.outstanding(), 0);
    assert_eq!(breaker.successes(secs(30)), 0);
    assert_matches!(breaker.admit(secs(30)), Ok(Admitted::Probe(_)));
}

#[test]
fn the_concurrency_limit_refuses_until_a_ticket_returns() {
    let bounded = Policy::new(
        Threshold::new(Some(nz(5)), None, 0).expect("valid"),
        secs(60),
        Recovery::new(secs(30), 0.0, nz(1), nz(1)).expect("valid"),
        Some(nz(2)),
    )
    .expect("valid");
    let mut breaker = Breaker::<16>::new(bounded);
    let mut first = breaker.admit(secs(0)).expect("one").into_ticket();
    let mut second = breaker.admit(secs(0)).expect("two").into_ticket();
    refuses(&mut breaker, Refusal::Full, |b| b.admit(secs(0)));
    breaker
        .complete(&mut first, Outcome::Success, secs(1), 0)
        .expect("completed");
    let mut third = breaker.admit(secs(1)).expect("slot freed").into_ticket();
    breaker.abandon(&mut second).expect("abandoned");
    breaker.abandon(&mut third).expect("abandoned");
    assert_eq!(breaker.outstanding(), 0);
}

#[test]
fn an_unbounded_breaker_refuses_a_ticket_it_could_not_count() {
    let mut breaker = Breaker::<16>::new(policy(3, 0.0, 1, 1));
    breaker.outstanding = u32::MAX - 1;
    let mut last = breaker
        .admit(secs(0))
        .expect("the last countable")
        .into_ticket();
    assert_eq!(breaker.outstanding(), u32::MAX);
    refuses(&mut breaker, Refusal::Full, |b| b.admit(secs(0)));
    breaker.abandon(&mut last).expect("abandoned");
    let mut freed = breaker.admit(secs(0)).expect("a slot freed").into_ticket();
    breaker.abandon(&mut freed).expect("abandoned");
}

#[test]
fn time_regression_is_refused_everywhere() {
    let mut breaker = Breaker::<16>::new(policy(3, 0.0, 1, 1));
    let mut ticket = breaker.admit(secs(10)).expect("call").into_ticket();
    refuses(&mut breaker, Refusal::TimeRegression, |b| b.admit(secs(9)));
    refuses(&mut breaker, Refusal::TimeRegression, |b| {
        b.observe(Outcome::Failure, secs(1), secs(9), 0)
    });
    refuses(&mut breaker, Refusal::TimeRegression, |b| {
        b.force_open(secs(9), 0)
    });
    refuses(&mut breaker, Refusal::TimeRegression, |b| {
        b.complete(&mut ticket, Outcome::Failure, secs(9), 0)
    });
    assert_eq!(ticket.settled(), None, "a refused ticket stays live");
    assert_eq!(breaker.latest(), secs(10));
    breaker
        .complete(&mut ticket, Outcome::Success, secs(10), 0)
        .expect("same instant is fine");
}

#[test]
fn foreign_tickets_are_unknown() {
    let mut ours = Breaker::<16>::with_scope(policy(3, 0.0, 1, 1), 1);
    let mut theirs = Breaker::<16>::with_scope(policy(3, 0.0, 1, 1), 2);
    let mut foreign = theirs.admit(secs(0)).expect("call").into_ticket();
    let mut held = ours.admit(secs(0)).expect("call").into_ticket();
    let before = ours.clone();
    assert_eq!(
        ours.complete(&mut foreign, Outcome::Failure, secs(1), 0),
        Err(Refusal::Unknown)
    );
    assert_eq!(ours, before);

    // Same scope, another breaker: the issuer cannot tell, but nothing is
    // outstanding for it to free.
    let mut twin = Breaker::<16>::with_scope(policy(3, 0.0, 1, 1), 1);
    let before = twin.clone();
    assert_eq!(twin.abandon(&mut held), Err(Refusal::Unknown));
    assert_eq!(twin, before);
    assert_eq!(ours.scope(), 1);
}

#[test]
fn jitter_is_drawn_once_per_opening_within_bounds() {
    let mut exact = Breaker::<16>::new(policy(1, 0.5, 1, 1));
    exact.force_open(secs(0), 0).expect("forced");
    assert_eq!(
        exact.retry_at(),
        Some(secs(30)),
        "a zero draw is unjittered"
    );

    let mut jittered = Breaker::<16>::new(policy(1, 0.5, 1, 1));
    jittered.force_open(secs(0), u64::MAX / 2).expect("forced");
    let retry_at = jittered.retry_at().expect("open");
    assert!(retry_at >= secs(15) && retry_at < secs(30), "{retry_at:?}");
    unchanged(&mut jittered, |b| b.retry_after(secs(1)));
}

#[test]
fn observe_runs_the_machine_without_admission() {
    let mut breaker = Breaker::<16>::new(policy(2, 0.0, 1, 1));
    assert_eq!(
        breaker.observe(Outcome::Failure, secs(1), secs(1), 0),
        Ok(Observed::Settled(Settled::Counted))
    );
    assert_eq!(
        breaker.observe(Outcome::Failure, secs(1), secs(2), 0),
        Ok(Observed::Settled(Settled::Opened))
    );
    assert_eq!(
        breaker.observe(Outcome::Failure, secs(1), secs(3), 0),
        Ok(Observed::Settled(Settled::Counted)),
        "inside the cooldown it records but drives nothing"
    );
    assert_eq!(breaker.retry_at(), Some(secs(32)));
    assert_eq!(
        breaker.observe(Outcome::Success, secs(1), secs(32), 0),
        Ok(Observed::HalfOpened(Settled::Closed))
    );
    assert_eq!(breaker.outstanding(), 0, "observe takes no slot");
}

#[test]
fn the_window_forgets_old_and_overflowing_outcomes() {
    let mut breaker = Breaker::<4>::new(policy(3, 0.0, 1, 1));
    for at in 0..2 {
        breaker
            .observe(Outcome::Failure, Duration::ZERO, secs(at), 0)
            .expect("observed");
    }
    assert_eq!(breaker.failures(secs(60)), 2, "the boundary instant counts");
    assert_eq!(breaker.failures(secs(61)), 1);
    assert_eq!(
        breaker.observe(Outcome::Failure, Duration::ZERO, secs(62), 0),
        Ok(Observed::Settled(Settled::Counted)),
        "the expired failures no longer count"
    );
    for at in 63..66 {
        breaker
            .observe(Outcome::Success, Duration::ZERO, secs(at), 0)
            .expect("observed");
    }
    // Capacity 4: the failure at 0 and 1 were evicted by the newest four.
    let mut out = [Event::default(); 8];
    assert_eq!(breaker.events(&mut out), 4);
    assert_eq!(out[0].at, secs(62));
    assert_eq!(out[3].at, secs(65));
    let mut newest = [Event::default(); 2];
    assert_eq!(breaker.events(&mut newest), 2);
    assert_eq!(newest[0].at, secs(64));
    assert_eq!(newest[1].at, secs(65));
}

#[test]
fn rate_threshold_waits_for_minimum_calls() {
    let rated = Policy::new(
        Threshold::new(None, Some(0.5), 4).expect("valid"),
        secs(60),
        Recovery::new(secs(30), 0.0, nz(1), nz(1)).expect("valid"),
        None,
    )
    .expect("valid");
    let mut breaker = Breaker::<16>::new(rated);
    assert_eq!(
        call(&mut breaker, Outcome::Failure, secs(0)),
        Settled::Counted
    );
    assert_eq!(
        call(&mut breaker, Outcome::Failure, secs(0)),
        Settled::Counted
    );
    assert_eq!(
        call(&mut breaker, Outcome::Success, secs(0)),
        Settled::Counted
    );
    assert_eq!(
        call(&mut breaker, Outcome::Failure, secs(0)),
        Settled::Opened
    );
}

#[test]
fn force_close_and_reset() {
    let mut breaker = Breaker::<16>::new(policy(3, 0.0, 1, 1));
    unchanged(&mut breaker, |b| {
        assert_eq!(b.force_close(), Ok(ForceClosed::AlreadyClosed));
    });

    let mut breaker = opened(secs(0));
    assert_eq!(breaker.force_close(), Ok(ForceClosed::Closed));
    assert_eq!(breaker.failures(secs(1)), 3, "force_close keeps the window");
    assert_eq!(
        call(&mut breaker, Outcome::Failure, secs(1)),
        Settled::Opened
    );

    let mut held = breaker.admit(secs(31)).expect("probe").into_ticket();
    breaker.reset().expect("an epoch is left");
    assert_eq!(breaker.state(), State::Closed);
    assert_eq!(breaker.failures(secs(31)), 0);
    assert_eq!(breaker.outstanding(), 1, "reset keeps concurrency slots");
    assert_eq!(
        breaker.complete(&mut held, Outcome::Failure, secs(32), 0),
        Ok(Completed::Settled(Settled::Counted)),
        "a ticket from before the reset cannot trip it"
    );
}

#[test]
fn names_and_refusal_messages() {
    assert_eq!(State::HalfOpen.name(), "half_open");
    assert_eq!(State::Closed.name(), "closed");
    assert_eq!(State::Open.name(), "open");
    assert_eq!(
        std::format!("{}", Refusal::TimeRegression),
        "time is earlier than the latest honoured instant"
    );
}

#[test]
fn a_repeated_settlement_is_a_duplicate_and_another_is_a_mismatch() {
    let mut breaker = Breaker::<16>::new(policy(1, 0.0, 1, 1));
    let mut failed = breaker.admit(secs(0)).expect("call").into_ticket();
    assert_eq!(
        breaker.complete(&mut failed, Outcome::Failure, secs(1), 0),
        Ok(Completed::Settled(Settled::Opened))
    );
    assert_eq!(
        failed.settled(),
        Some(Settlement::Completed(Outcome::Failure, Settled::Opened))
    );
    unchanged(&mut breaker, |b| {
        assert_eq!(
            b.complete(&mut failed, Outcome::Failure, secs(0), 0),
            Ok(Completed::Duplicate(Settled::Opened)),
            "a duplicate holds whatever the time"
        );
    });
    refuses(&mut breaker, Refusal::Mismatch, |b| {
        b.complete(&mut failed, Outcome::Success, secs(2), 0)
    });
    refuses(&mut breaker, Refusal::Mismatch, |b| b.abandon(&mut failed));

    breaker.reset().expect("an epoch is left");
    let mut dropped = breaker.admit(secs(2)).expect("call").into_ticket();
    assert_eq!(breaker.abandon(&mut dropped), Ok(Abandoned::Released));
    unchanged(&mut breaker, |b| {
        assert_eq!(b.abandon(&mut dropped), Ok(Abandoned::Duplicate));
    });
    refuses(&mut breaker, Refusal::Mismatch, |b| {
        b.complete(&mut dropped, Outcome::Success, secs(2), 0)
    });
}
