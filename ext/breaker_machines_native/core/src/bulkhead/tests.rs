use super::*;
use std::thread;

#[test]
fn test_bulkhead_basic_acquire_release() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(3));

    assert_eq!(bulkhead.limit(), 3);
    assert_eq!(bulkhead.acquired(), 0);
    assert_eq!(bulkhead.available(), 3);

    // Acquire first permit
    let guard1 = bulkhead.try_acquire();
    assert!(guard1.is_some());
    assert_eq!(bulkhead.acquired(), 1);
    assert_eq!(bulkhead.available(), 2);

    // Acquire second permit
    let guard2 = bulkhead.try_acquire();
    assert!(guard2.is_some());
    assert_eq!(bulkhead.acquired(), 2);

    // Release first permit
    drop(guard1);
    assert_eq!(bulkhead.acquired(), 1);
    assert_eq!(bulkhead.available(), 2);

    // Release second permit
    drop(guard2);
    assert_eq!(bulkhead.acquired(), 0);
    assert_eq!(bulkhead.available(), 3);
}

#[test]
fn test_bulkhead_at_capacity() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(2));

    let guard1 = bulkhead.try_acquire().expect("Should acquire");
    let guard2 = bulkhead.try_acquire().expect("Should acquire");

    // At capacity - should fail
    let guard3 = bulkhead.try_acquire();
    assert!(guard3.is_none(), "Should not acquire when at capacity");
    assert_eq!(bulkhead.acquired(), 2);

    // Release one permit
    drop(guard1);

    // Now should succeed
    let guard4 = bulkhead.try_acquire();
    assert!(guard4.is_some(), "Should acquire after release");
    assert_eq!(bulkhead.acquired(), 2);

    drop(guard2);
    drop(guard4);
}

#[test]
fn test_bulkhead_concurrent_access() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(5));
    let mut handles = vec![];

    // Spawn 10 threads trying to acquire permits
    for _ in 0..10 {
        let bulkhead_clone = Arc::clone(&bulkhead);
        let handle = thread::spawn(move || {
            if let Some(_guard) = bulkhead_clone.try_acquire() {
                // Hold the permit briefly
                thread::sleep(std::time::Duration::from_millis(10));
                true
            } else {
                false
            }
        });
        handles.push(handle);
    }

    // Wait for all threads
    let mut acquired_count = 0;
    for handle in handles {
        if handle.join().unwrap() {
            acquired_count += 1;
        }
    }

    // At least 5 should have succeeded (limit is 5)
    assert!(
        acquired_count >= 5,
        "At least 5 threads should acquire permits"
    );

    // All permits should be released now
    assert_eq!(bulkhead.acquired(), 0);
}

#[test]
#[should_panic(expected = "Bulkhead limit must be greater than 0")]
fn test_bulkhead_zero_limit() {
    BulkheadSemaphore::new(0);
}

#[test]
fn test_bulkhead_guard_releases_on_panic() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(2));

    let bulkhead_clone = Arc::clone(&bulkhead);
    let result = std::panic::catch_unwind(move || {
        let _guard = bulkhead_clone.try_acquire().unwrap();
        panic!("Simulated panic");
    });

    assert!(result.is_err());
    // Guard should have been dropped and permit released
    assert_eq!(bulkhead.acquired(), 0);
}
