use super::*;

#[test]
fn ruby_state_names_match_the_lowercased_state_names() {
    for state in [
        CircuitState::Closed,
        CircuitState::Open,
        CircuitState::HalfOpen,
    ] {
        assert_eq!(
            ruby_state_name(state),
            state.name().to_lowercase(),
            "state: {state:?}"
        );
    }
}
