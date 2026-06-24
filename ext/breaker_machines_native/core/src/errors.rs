//! Error types for circuit breaker operations

use alloc::boxed::Box;
use alloc::string::String;
use core::error::Error;
use core::fmt;

/// Errors that can occur during circuit breaker operations
#[derive(Debug)]
pub enum CircuitError<E = Box<dyn Error + Send + Sync>> {
    /// Circuit is open, calls are being rejected
    Open { circuit: String, opened_at: f64 },
    /// Half-open request limit has been reached
    HalfOpenLimitReached { circuit: String },
    /// Bulkhead is at capacity, cannot acquire permit
    BulkheadFull { circuit: String, limit: usize },
    /// The wrapped operation failed
    Execution(E),
}

impl<E: fmt::Display> fmt::Display for CircuitError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CircuitError::Open { circuit, opened_at } => {
                write!(f, "Circuit '{circuit}' is open (opened at {opened_at})")
            }
            CircuitError::HalfOpenLimitReached { circuit } => {
                write!(f, "Circuit '{circuit}' half-open request limit reached")
            }
            CircuitError::BulkheadFull { circuit, limit } => {
                write!(f, "Circuit '{circuit}' bulkhead is full (limit: {limit})")
            }
            CircuitError::Execution(e) => write!(f, "Circuit execution failed: {e}"),
        }
    }
}

impl<E: Error + 'static> Error for CircuitError<E> {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            CircuitError::Execution(e) => Some(e),
            _ => None,
        }
    }
}
