use super::*;

fn failure(error: &dyn Any, duration: f64) -> FailureContext<'_> {
    FailureContext {
        circuit_name: "test",
        error,
        duration,
    }
}

#[test]
fn default_classifier_trips_on_everything() {
    assert!(DefaultClassifier.should_trip(&failure(&"any error", 0.1)));
}

#[test]
fn predicate_classifier_applies_its_closure() {
    let slow_only = PredicateClassifier::new(|ctx| ctx.duration > 1.0);

    assert!(!slow_only.should_trip(&failure(&"fast error", 0.5)));
    assert!(slow_only.should_trip(&failure(&"slow error", 2.0)));
}

#[test]
fn predicate_can_downcast_the_error() {
    #[derive(Debug)]
    struct HttpError {
        server_side: bool,
    }

    // Trip on server errors; unknown error types trip too.
    let classifier = PredicateClassifier::new(|ctx| {
        ctx.error
            .downcast_ref::<HttpError>()
            .is_none_or(|error| error.server_side)
    });

    assert!(classifier.should_trip(&failure(&HttpError { server_side: true }, 0.1)));
    assert!(!classifier.should_trip(&failure(&HttpError { server_side: false }, 0.1)));
    assert!(classifier.should_trip(&failure(&"unknown", 0.1)));
}
