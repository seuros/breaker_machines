use super::*;

#[test]
fn ruby_state_names_match_the_pure_ruby_circuit() {
    const CASES: &[(CircuitState, &str)] = &[
        (CircuitState::Closed, "closed"),
        (CircuitState::Open, "open"),
        (CircuitState::HalfOpen, "half_open"),
    ];
    for &(state, expected) in CASES {
        assert_eq!(ruby_state_name(state), expected, "state: {state:?}");
    }
}
