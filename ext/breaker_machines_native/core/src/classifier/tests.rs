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
