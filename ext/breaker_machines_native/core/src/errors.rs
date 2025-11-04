//! Error types for circuit breaker operations

use std::error::Error;
use std::fmt;

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
                write!(f, "Circuit '{}' is open (opened at {})", circuit, opened_at)
            }
            CircuitError::HalfOpenLimitReached { circuit } => {
                write!(f, "Circuit '{}' half-open request limit reached", circuit)
            }
            CircuitError::BulkheadFull { circuit, limit } => {
                write!(
                    f,
                    "Circuit '{}' bulkhead is full (limit: {})",
                    circuit, limit
                )
            }
            CircuitError::Execution(e) => write!(f, "Circuit execution failed: {}", e),
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
