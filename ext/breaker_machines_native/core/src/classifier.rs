//! Deciding which errors count against a runtime circuit.

use core::any::Any;
use core::time::Duration;

/// What a classifier sees of a failed call.
#[derive(Debug)]
pub struct FailureContext<'a> {
    /// The circuit's name.
    pub circuit_name: &'a str,
    /// The error, to downcast to the caller's own types.
    pub error: &'a dyn Any,
    /// How long the call ran.
    pub took: Duration,
}

/// Decides whether a failed call counts against the circuit. An error that
/// does not count is abandoned: it frees its slots and is not recorded.
pub trait FailureClassifier: Send + Sync + core::fmt::Debug {
    /// `true` when the failure counts.
    fn should_trip(&self, ctx: &FailureContext<'_>) -> bool;
}

/// A classifier from a closure.
pub struct PredicateClassifier<F>
where
    F: Fn(&FailureContext<'_>) -> bool + Send + Sync,
{
    predicate: F,
}

impl<F> PredicateClassifier<F>
where
    F: Fn(&FailureContext<'_>) -> bool + Send + Sync,
{
    /// A classifier that counts the failures `predicate` accepts.
    pub const fn new(predicate: F) -> Self {
        Self { predicate }
    }
}

impl<F> FailureClassifier for PredicateClassifier<F>
where
    F: Fn(&FailureContext<'_>) -> bool + Send + Sync,
{
    fn should_trip(&self, ctx: &FailureContext<'_>) -> bool {
        (self.predicate)(ctx)
    }
}

impl<F> core::fmt::Debug for PredicateClassifier<F>
where
    F: Fn(&FailureContext<'_>) -> bool + Send + Sync,
{
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("PredicateClassifier")
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests;
