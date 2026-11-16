use super::*;

fn failure(error: &dyn Any, took: Duration) -> FailureContext<'_> {
    FailureContext {
        circuit_name: "test",
        error,
        took,
    }
}

#[test]
fn predicate_classifier_applies_its_closure() {
    let slow_only = PredicateClassifier::new(|ctx| ctx.took > Duration::from_secs(1));
    assert!(!slow_only.should_trip(&failure(&"fast", Duration::from_millis(500))));
    assert!(slow_only.should_trip(&failure(&"slow", Duration::from_secs(2))));
    assert_eq!(std::format!("{slow_only:?}"), "PredicateClassifier { .. }");
}

#[test]
fn predicate_can_downcast_the_error() {
    #[derive(Debug)]
    struct HttpError {
        server_side: bool,
    }
    let classifier = PredicateClassifier::new(|ctx| {
        ctx.error
            .downcast_ref::<HttpError>()
            .is_none_or(|error| error.server_side)
    });
    assert!(classifier.should_trip(&failure(&HttpError { server_side: true }, Duration::ZERO)));
    assert!(!classifier.should_trip(&failure(&HttpError { server_side: false }, Duration::ZERO)));
    assert!(classifier.should_trip(&failure(&"unknown type", Duration::ZERO)));
}
