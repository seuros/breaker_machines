#![no_std]
#![cfg_attr(not(test), deny(clippy::indexing_slicing))]
#![doc = include_str!("../README.md")]

#[cfg(any(feature = "std", test))]
extern crate std;

mod answer;
mod breaker;
mod policy;
mod refusal;

#[cfg(feature = "async")]
mod async_circuit;
#[cfg(feature = "std")]
mod callbacks;
#[cfg(feature = "std")]
mod circuit;
#[cfg(feature = "std")]
mod classifier;
#[cfg(feature = "std")]
mod clock;
#[cfg(feature = "async")]
mod distributed;
#[cfg(feature = "std")]
mod error;
#[cfg(feature = "std")]
mod lifecycle;
#[cfg(feature = "async")]
mod storage;
#[cfg(all(test, feature = "std"))]
mod test_support;

pub use answer::{
    Abandoned, Admitted, Adopted, Completed, Event, ForceClosed, Kind, Observed, Outcome, Settled,
    Settlement, State, Status, Ticket,
};
pub use breaker::Breaker;
pub use chrono_machines;
pub use periscope_machines;
pub use policy::{Policy, Recovery, Threshold};
pub use refusal::Refusal;

#[cfg(feature = "async")]
pub use async_circuit::{AsyncCircuitBreaker, AsyncTicket};
#[cfg(feature = "std")]
pub use callbacks::{CallbackFn, Callbacks};
#[cfg(feature = "std")]
pub use circuit::{CircuitBreaker, CircuitBuilder, WINDOW};
#[cfg(feature = "std")]
pub use classifier::{FailureClassifier, FailureContext, PredicateClassifier};
#[cfg(feature = "std")]
pub use clock::{Clock, SystemClock};
#[cfg(feature = "async")]
pub use distributed::DistributedCircuitBreaker;
#[cfg(feature = "std")]
pub use error::{CircuitError, FallbackContext, StorageError};
#[cfg(feature = "async")]
pub use storage::{
    Applied, AsyncStorageBackend, CircuitSnapshot, FailurePolicy, MemoryStorage, ProbeDecision,
    ProbeLease, ProbePolicy, StateTransition, StorageFuture, StorageUpdate, StoredOutcome,
};
