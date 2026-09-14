//! Bulkhead implementation for concurrency limiting
//!
//! This module provides a semaphore-based bulkhead pattern to limit
//! the number of concurrent calls through a circuit breaker.

use alloc::sync::Arc;
use core::sync::atomic::{AtomicUsize, Ordering};

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
        self.limit - self.acquired()
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
mod tests;
