//! BreakerMachines - High-performance circuit breaker implementation
//!
//! This crate provides a complete circuit breaker implementation with:
//! - Thread-safe event storage with sliding window calculations
//! - State machine for circuit breaker lifecycle (Closed → Open → HalfOpen)
//! - Monotonic time tracking to prevent NTP clock skew issues
//! - Configurable failure thresholds and timeouts
//!
//! # Example
//!
//! ```rust
//! use breaker_machines::CircuitBreaker;
//!
//! let mut circuit = CircuitBreaker::builder("my_service")
//!     .failure_threshold(5)
//!     .failure_window_secs(60.0)
//!     .half_open_timeout_secs(30.0)
//!     .success_threshold(2)
//!     .on_open(|name| println!("Circuit {} opened!", name))
//!     .build();
//!
//! // Execute with circuit protection
//! let result = circuit.call(|| {
//!     // Your service call here
//!     Ok::<_, String>("success")
//! });
//!
//! // Check circuit state
//! if circuit.is_open() {
//!     println!("Circuit is open, skipping call");
//! }
//! ```

pub mod builder;
pub mod bulkhead;
pub mod callbacks;
pub mod circuit;
pub mod classifier;
pub mod errors;
pub mod storage;

pub use builder::CircuitBuilder;
pub use bulkhead::{BulkheadGuard, BulkheadSemaphore};
pub use circuit::{CallOptions, CircuitBreaker, Config, FallbackContext};
pub use classifier::{DefaultClassifier, FailureClassifier, FailureContext, PredicateClassifier};
pub use errors::CircuitError;
pub use storage::{MemoryStorage, NullStorage, StorageBackend};

/// Event type for circuit breaker operations
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Success,
    Failure,
}

/// A single event recorded by the circuit breaker
#[derive(Debug, Clone)]
pub struct Event {
    pub kind: EventKind,
    pub timestamp: f64,
    pub duration: f64,
}
