//! Failure classification for exception filtering
//!
//! This module provides traits and types for determining which errors
//! should trip the circuit breaker vs. being ignored.

use std::any::Any;

/// Context provided to failure classifiers for error evaluation
#[derive(Debug)]
pub struct FailureContext<'a> {
    /// Circuit name
    pub circuit_name: &'a str,
    /// The error that occurred (can be downcast to specific types)
    pub error: &'a dyn Any,
    /// Duration of the failed call in seconds
    pub duration: f64,
}

/// Trait for classifying failures - determines if an error should trip the circuit
///
/// Implementors can inspect the error type and context to decide whether
/// this particular failure should count toward opening the circuit.
///
/// # Examples
///
/// ```rust
/// use breaker_machines::{FailureClassifier, FailureContext};
/// use std::sync::Arc;
///
/// #[derive(Debug)]
/// struct ServerErrorClassifier;
///
/// impl FailureClassifier for ServerErrorClassifier {
///     fn should_trip(&self, ctx: &FailureContext<'_>) -> bool {
///         // Only trip on server errors (5xx), not client errors (4xx)
///         // This would require your error type to be downcast-able
///         true // Default: trip on all errors
///     }
/// }
/// ```
pub trait FailureClassifier: Send + Sync + std::fmt::Debug {
    /// Determine if this error should count as a failure for circuit breaker logic
    ///
    /// Returns `true` if the error should trip the circuit, `false` to ignore it.
    fn should_trip(&self, ctx: &FailureContext<'_>) -> bool;
}

/// Default classifier that trips on all errors
#[derive(Debug, Clone, Copy)]
pub struct DefaultClassifier;

impl FailureClassifier for DefaultClassifier {
    fn should_trip(&self, _ctx: &FailureContext<'_>) -> bool {
        true // All errors trip the circuit (backward compatible)
    }
}

impl Default for DefaultClassifier {
    fn default() -> Self {
        Self
    }
}

/// Predicate-based classifier using a closure
///
/// Allows using simple closures for common filtering patterns.
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
    /// Create a new predicate-based classifier
    pub fn new(predicate: F) -> Self {
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

impl<F> std::fmt::Debug for PredicateClassifier<F>
where
    F: Fn(&FailureContext<'_>) -> bool + Send + Sync,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PredicateClassifier")
            .field("predicate", &"<closure>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_classifier_trips_all() {
        let classifier = DefaultClassifier;
        let ctx = FailureContext {
            circuit_name: "test",
            error: &"any error" as &dyn Any,
            duration: 0.1,
        };

        assert!(classifier.should_trip(&ctx));
    }

    #[test]
    fn test_predicate_classifier() {
        // Classifier that only trips on slow errors
        let classifier = PredicateClassifier::new(|ctx| ctx.duration > 1.0);

        let fast_ctx = FailureContext {
            circuit_name: "test",
            error: &"fast error" as &dyn Any,
            duration: 0.5,
        };

        let slow_ctx = FailureContext {
            circuit_name: "test",
            error: &"slow error" as &dyn Any,
            duration: 2.0,
        };

        assert!(!classifier.should_trip(&fast_ctx));
        assert!(classifier.should_trip(&slow_ctx));
    }

    #[test]
    fn test_error_type_downcast() {
        #[derive(Debug)]
        struct MyError {
            is_server_error: bool,
        }

        let server_error = MyError {
            is_server_error: true,
        };
        let client_error = MyError {
            is_server_error: false,
        };

        let classifier = PredicateClassifier::new(|ctx| {
            ctx.error
                .downcast_ref::<MyError>()
                .map(|e| e.is_server_error)
                .unwrap_or(true) // Trip on unknown errors
        });

        let server_ctx = FailureContext {
            circuit_name: "test",
            error: &server_error as &dyn Any,
            duration: 0.1,
        };

        let client_ctx = FailureContext {
            circuit_name: "test",
            error: &client_error as &dyn Any,
            duration: 0.1,
        };

        assert!(classifier.should_trip(&server_ctx));
        assert!(!classifier.should_trip(&client_ctx));
    }
}
