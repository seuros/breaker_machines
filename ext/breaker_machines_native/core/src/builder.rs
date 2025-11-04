//! Builder API for ergonomic circuit breaker configuration

use crate::{
    MemoryStorage, StorageBackend,
    bulkhead::BulkheadSemaphore,
    callbacks::Callbacks,
    circuit::{CircuitBreaker, CircuitContext, Config},
    classifier::FailureClassifier,
};
use std::sync::Arc;

/// Builder for creating circuit breakers with fluent API
pub struct CircuitBuilder {
    name: String,
    config: Config,
    storage: Option<Arc<dyn StorageBackend>>,
    failure_classifier: Option<Arc<dyn FailureClassifier>>,
    bulkhead: Option<Arc<BulkheadSemaphore>>,
    callbacks: Callbacks,
}

impl CircuitBuilder {
    /// Create a new builder for a circuit with the given name
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            config: Config::default(),
            storage: None,
            failure_classifier: None,
            bulkhead: None,
            callbacks: Callbacks::new(),
        }
    }

    /// Set the absolute failure threshold (number of failures to open circuit)
    pub fn failure_threshold(mut self, threshold: usize) -> Self {
        self.config.failure_threshold = Some(threshold);
        self
    }

    /// Disable absolute failure threshold (use only rate-based)
    pub fn disable_failure_threshold(mut self) -> Self {
        self.config.failure_threshold = None;
        self
    }

    /// Set the failure rate threshold (0.0-1.0)
    /// Circuit opens when (failures / total_calls) >= this value
    pub fn failure_rate(mut self, rate: f64) -> Self {
        self.config.failure_rate_threshold = Some(rate.clamp(0.0, 1.0));
        self
    }

    /// Set minimum number of calls before rate-based threshold is evaluated
    pub fn minimum_calls(mut self, calls: usize) -> Self {
        self.config.minimum_calls = calls;
        self
    }

    /// Set the failure window in seconds
    pub fn failure_window_secs(mut self, seconds: f64) -> Self {
        self.config.failure_window_secs = seconds;
        self
    }

    /// Set the half-open timeout in seconds
    pub fn half_open_timeout_secs(mut self, seconds: f64) -> Self {
        self.config.half_open_timeout_secs = seconds;
        self
    }

    /// Set the success threshold (successes needed to close from half-open)
    pub fn success_threshold(mut self, threshold: usize) -> Self {
        self.config.success_threshold = threshold;
        self
    }

    /// Set the jitter factor (0.0 = no jitter, 1.0 = full jitter)
    /// Uses chrono-machines formula: timeout * (1 - jitter + rand * jitter)
    pub fn jitter_factor(mut self, factor: f64) -> Self {
        self.config.jitter_factor = factor;
        self
    }

    /// Set custom storage backend
    pub fn storage(mut self, storage: Arc<dyn StorageBackend>) -> Self {
        self.storage = Some(storage);
        self
    }

    /// Set a failure classifier to filter which errors should trip the circuit
    ///
    /// The classifier determines whether a given error should count toward
    /// opening the circuit. Use this to ignore "expected" errors like validation
    /// failures or client errors (4xx), while still tripping on server errors (5xx).
    ///
    /// # Examples
    ///
    /// ```rust
    /// use breaker_machines::{CircuitBreaker, PredicateClassifier};
    /// use std::sync::Arc;
    ///
    /// let circuit = CircuitBreaker::builder("api")
    ///     .failure_classifier(Arc::new(PredicateClassifier::new(|ctx| {
    ///         // Only trip on slow errors
    ///         ctx.duration > 1.0
    ///     })))
    ///     .build();
    /// ```
    pub fn failure_classifier(mut self, classifier: Arc<dyn FailureClassifier>) -> Self {
        self.failure_classifier = Some(classifier);
        self
    }

    /// Set maximum concurrency limit (bulkheading)
    ///
    /// When set, the circuit breaker will reject calls with `BulkheadFull` error
    /// if the number of concurrent calls exceeds this limit. This prevents
    /// resource exhaustion by limiting how many operations can run simultaneously.
    ///
    /// # Panics
    ///
    /// Panics if `limit` is 0.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use breaker_machines::CircuitBreaker;
    ///
    /// let mut circuit = CircuitBreaker::builder("api")
    ///     .max_concurrency(10) // Allow max 10 concurrent calls
    ///     .build();
    ///
    /// // This will succeed until 10 calls are running concurrently
    /// let result = circuit.call(|| Ok::<_, String>("success"));
    /// ```
    pub fn max_concurrency(mut self, limit: usize) -> Self {
        self.bulkhead = Some(Arc::new(BulkheadSemaphore::new(limit)));
        self
    }

    /// Set callback for when circuit opens
    pub fn on_open<F>(mut self, f: F) -> Self
    where
        F: Fn(&str) + Send + Sync + 'static,
    {
        self.callbacks.on_open = Some(Arc::new(f));
        self
    }

    /// Set callback for when circuit closes
    pub fn on_close<F>(mut self, f: F) -> Self
    where
        F: Fn(&str) + Send + Sync + 'static,
    {
        self.callbacks.on_close = Some(Arc::new(f));
        self
    }

    /// Set callback for when circuit enters half-open
    pub fn on_half_open<F>(mut self, f: F) -> Self
    where
        F: Fn(&str) + Send + Sync + 'static,
    {
        self.callbacks.on_half_open = Some(Arc::new(f));
        self
    }

    /// Build the circuit breaker
    pub fn build(self) -> CircuitBreaker {
        let storage = self
            .storage
            .unwrap_or_else(|| Arc::new(MemoryStorage::new()));

        let context = CircuitContext {
            name: self.name,
            config: self.config,
            storage,
            failure_classifier: self.failure_classifier,
            bulkhead: self.bulkhead,
        };

        CircuitBreaker::with_context_and_callbacks(context, self.callbacks)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_builder_defaults() {
        let circuit = CircuitBuilder::new("test").build();

        assert_eq!(circuit.state_name(), "Closed");
        assert!(circuit.is_closed());
    }

    #[test]
    fn test_builder_custom_config() {
        let circuit = CircuitBuilder::new("test")
            .failure_threshold(10)
            .failure_window_secs(120.0)
            .half_open_timeout_secs(60.0)
            .success_threshold(3)
            .build();

        assert!(circuit.is_closed());
    }

    #[test]
    fn test_builder_with_callbacks() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let opened = Arc::new(AtomicBool::new(false));
        let opened_clone = opened.clone();

        let mut circuit = CircuitBuilder::new("test")
            .failure_threshold(2)
            .on_open(move |_name| {
                opened_clone.store(true, Ordering::SeqCst);
            })
            .build();

        // Trigger failures to open circuit
        let _ = circuit.call(|| Err::<(), _>("error 1"));
        let _ = circuit.call(|| Err::<(), _>("error 2"));

        // Callback should have been triggered
        assert!(opened.load(Ordering::SeqCst));
    }
}
