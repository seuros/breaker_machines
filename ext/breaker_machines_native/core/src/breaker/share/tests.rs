use crate::breaker::tests::{opened, policy, secs};
use crate::{Adopted, Breaker, Completed, Outcome, Settled, State, Status};
use matryona_machines::testing::unchanged;

#[test]
fn statuses_validate_and_adopting_one_moves_the_breaker() {
    assert_eq!(Status::new(State::Open, Some(secs(5)), Some(secs(4))), None);
    assert_eq!(Status::new(State::Open, Some(secs(5)), None), None);
    assert_eq!(Status::new(State::Closed, Some(secs(5)), None), None);
    assert_eq!(Status::new(State::HalfOpen, None, Some(secs(5))), None);
    let open = Status::new(State::Open, Some(secs(5)), Some(secs(35))).expect("valid");
    assert_eq!(open.opened_at(), Some(secs(5)));

    let mut source = opened(secs(5));
    assert_eq!(source.status(), open);
    let mut mirror = Breaker::<16>::new(policy(3, 0.0, 2, 1));
    let held = mirror.admit(secs(1)).expect("call");
    assert_eq!(mirror.adopt(open), Ok(Adopted::Opened));
    assert_eq!(mirror.retry_at(), Some(secs(35)));
    unchanged(&mut mirror, |b| {
        assert_eq!(b.adopt(open), Ok(Adopted::Unchanged));
    });
    let mut held = held.into_ticket();
    assert_eq!(
        mirror.complete(&mut held, Outcome::Failure, secs(6), 0),
        Ok(Completed::Settled(Settled::Counted)),
        "a ticket from before the adoption is fenced"
    );

    let half_open = Status::new(State::HalfOpen, None, None).expect("valid");
    assert_eq!(mirror.adopt(half_open), Ok(Adopted::HalfOpened));
    assert_eq!(mirror.half_open_attempts(), 0);
    let closed = Status::new(State::Closed, None, None).expect("valid");
    assert_eq!(mirror.adopt(closed), Ok(Adopted::Closed));
    assert_eq!(
        mirror.failures(secs(6)),
        0,
        "adopting a recovery starts a fresh window"
    );
    assert_eq!(source.adopt(closed), Ok(Adopted::Closed));
    assert_eq!(source.state(), State::Closed);
}
