use super::*;
use core::assert_matches;
use core::time::Duration;
use std::thread;

#[test]
fn acquire_and_release_track_permits() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(3));
    assert_eq!(
        (bulkhead.limit(), bulkhead.acquired(), bulkhead.available()),
        (3, 0, 3)
    );

    let first = bulkhead.try_acquire();
    assert_matches!(first, Some(_));
    assert_eq!((bulkhead.acquired(), bulkhead.available()), (1, 2));

    let second = bulkhead.try_acquire();
    assert_matches!(second, Some(_));
    assert_eq!(bulkhead.acquired(), 2);

    drop(first);
    assert_eq!((bulkhead.acquired(), bulkhead.available()), (1, 2));

    drop(second);
    assert_eq!((bulkhead.acquired(), bulkhead.available()), (0, 3));
}

#[test]
fn rejects_at_capacity_until_a_permit_is_released() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(2));
    let first = bulkhead.try_acquire();
    let _second = bulkhead.try_acquire();

    assert_matches!(bulkhead.try_acquire(), None, "acquired past capacity");
    assert_eq!(bulkhead.acquired(), 2);

    drop(first);

    assert_matches!(bulkhead.try_acquire(), Some(_), "no permit after release");
}

#[test]
fn concurrent_acquires_never_exceed_the_limit() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(5));

    let admitted = thread::scope(|scope| {
        #[expect(
            clippy::needless_collect,
            reason = "spawn every worker before joining any"
        )]
        let workers: Vec<_> = (0..10)
            .map(|_| {
                scope.spawn(|| {
                    let permit = bulkhead.try_acquire()?;
                    let in_use = bulkhead.acquired();
                    thread::sleep(Duration::from_millis(10));
                    drop(permit);
                    Some(in_use)
                })
            })
            .collect();

        workers
            .into_iter()
            .filter_map(|worker| worker.join().expect("worker panicked"))
            .inspect(|&in_use| assert_matches!(in_use, 1..=5))
            .count()
    });

    assert_matches!(admitted, 5..=10);
    assert_eq!(bulkhead.acquired(), 0, "permits leaked");
}

#[test]
#[should_panic(expected = "Bulkhead limit must be greater than 0")]
fn zero_limit_panics() {
    BulkheadSemaphore::new(0);
}

#[test]
fn guard_releases_on_panic() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(2));

    let result = std::panic::catch_unwind(|| {
        let _permit = bulkhead.try_acquire();
        panic!("simulated panic");
    });

    assert_matches!(result, Err(_));
    assert_eq!(bulkhead.acquired(), 0);
}
