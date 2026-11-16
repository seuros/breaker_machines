//! Errors from runtime circuit calls.

use crate::Refusal;
use core::error::Error;
use core::fmt;
use core::time::Duration;
use std::boxed::Box;
use std::string::String;
use std::sync::Arc;

/// Why a guarded call did not return the operation's value.
#[derive(Debug, PartialEq, Eq)]
pub enum CircuitError<E = Box<dyn Error + Send + Sync>> {
    /// The circuit refused to admit the call, and no fallback ran.
    Refused {
        /// The circuit's name.
        circuit: Arc<str>,
        /// Why it refused.
        refusal: Refusal,
    },
    /// Distributed state storage failed.
    Storage(StorageError),
    /// The operation (or the fallback) failed with its own error.
    Execution(E),
}

impl<E: fmt::Display> fmt::Display for CircuitError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused { circuit, refusal } => {
                write!(f, "circuit '{circuit}' refused the call: {refusal}")
            }
            Self::Storage(error) => write!(f, "circuit storage failed: {error}"),
            Self::Execution(error) => write!(f, "circuit execution failed: {error}"),
        }
    }
}

impl<E: Error + 'static> Error for CircuitError<E> {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Refused { refusal, .. } => Some(refusal),
            Self::Storage(error) => Some(error),
            Self::Execution(error) => Some(error),
        }
    }
}

/// What a fallback learns about the refusal it replaces.
#[derive(Debug, Clone)]
pub struct FallbackContext {
    /// The circuit's name.
    pub circuit: Arc<str>,
    /// Why the call was refused.
    pub refusal: Refusal,
    /// How long until a probe may run, while the circuit is open.
    pub retry_after: Option<Duration>,
}

/// What kind of failure a [`StorageError`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageErrorKind {
    /// The store refused because a fencing identity (circuit generation or
    /// probe token) would have been reused; nothing changed. A
    /// [`DistributedCircuitBreaker`](crate::DistributedCircuitBreaker)
    /// answers it as [`Refusal::Exhausted`].
    Exhausted,
    /// The backend itself failed (connection, timeout, invalid record).
    Backend,
}

/// A distributed storage backend's failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageError {
    kind: StorageErrorKind,
    message: String,
}

impl StorageError {
    /// A storage error of `kind` carrying the backend's message.
    pub fn new(kind: StorageErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    /// What kind of failure this is.
    #[must_use]
    pub const fn kind(&self) -> StorageErrorKind {
        self.kind
    }

    /// The backend's message.
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for StorageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl Error for StorageError {}
