//! Bulkhead implementation for concurrency limiting
//!
//! This module provides a semaphore-based bulkhead pattern to limit
//! the number of concurrent calls through a circuit breaker.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A semaphore-based bulkhead for limiting concurrent operations
///
/// Bulkheading prevents thread pool exhaustion by rejecting requests
/// when a maximum concurrency limit is reached.
#[derive(Debug)]
pub struct BulkheadSemaphore {
    /// Maximum number of concurrent permits
    limit: usize,
    /// Current number of acquired permits
    acquired: AtomicUsize,
}

impl BulkheadSemaphore {
    /// Create a new bulkhead semaphore with the given concurrency limit
    ///
    /// # Panics
    ///
    /// Panics if `limit` is 0.
    pub fn new(limit: usize) -> Self {
        assert!(limit > 0, "Bulkhead limit must be greater than 0");
        Self {
            limit,
            acquired: AtomicUsize::new(0),
        }
    }

    /// Try to acquire a permit without blocking
    ///
    /// Returns `Some(BulkheadGuard)` if a permit was acquired, or `None` if
    /// the bulkhead is at capacity.
    pub fn try_acquire(self: &Arc<Self>) -> Option<BulkheadGuard> {
        // Try to increment the counter
        let mut current = self.acquired.load(Ordering::Acquire);

        loop {
            // Check if we're at capacity
            if current >= self.limit {
                return None;
            }

            // Try to increment atomically
            match self.acquired.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    // Successfully acquired permit
                    return Some(BulkheadGuard {
                        semaphore: Arc::clone(self),
                    });
                }
                Err(actual) => {
                    // Another thread modified the counter, try again
                    current = actual;
                }
            }
        }
    }

    /// Get the current number of acquired permits
    pub fn acquired(&self) -> usize {
        self.acquired.load(Ordering::Acquire)
    }

    /// Get the maximum number of permits (bulkhead limit)
    pub fn limit(&self) -> usize {
        self.limit
    }

    /// Get the number of available permits
    pub fn available(&self) -> usize {
        self.limit.saturating_sub(self.acquired())
    }

    /// Release a permit (called by BulkheadGuard on drop)
    fn release(&self) {
        self.acquired.fetch_sub(1, Ordering::Release);
    }
}

/// Guard that releases a bulkhead permit when dropped
///
/// This ensures that permits are always released, even if the guarded
/// operation panics.
#[derive(Debug)]
pub struct BulkheadGuard {
    semaphore: Arc<BulkheadSemaphore>,
}

impl Drop for BulkheadGuard {
    fn drop(&mut self) {
        self.semaphore.release();
    }
}

#[cfg(test)]
mod tests {
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
}
