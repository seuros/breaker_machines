use super::*;
use crate::test_support::ManualClock;
use crate::{Event, MemoryStorage, PredicateClassifier};
use core::assert_matches;
use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use core::time::Duration;
use state_machines::DynamicError;

fn context(config: Config, storage: Arc<MemoryStorage>) -> CircuitContext {
    CircuitContext {
        name: "test".into(),
        config,
        storage,
        ..CircuitContext::default()
    }
}

fn trip(machine: &mut DynamicCircuit) {
    machine
        .handle(CircuitEvent::Trip)
        .expect("threshold reached");
}

/// Counts every callback invocation, keyed by transition.
#[derive(Debug, Clone, Default)]
struct Transitions {
    opened: Arc<AtomicUsize>,
    half_opened: Arc<AtomicUsize>,
    closed: Arc<AtomicUsize>,
}

impl Transitions {
    fn attach(&self, builder: crate::CircuitBuilder) -> crate::CircuitBuilder {
        let (opened, half_opened, closed) = (
            Arc::clone(&self.opened),
            Arc::clone(&self.half_opened),
            Arc::clone(&self.closed),
        );
        builder
            .on_open(move |_| _ = opened.fetch_add(1, Ordering::SeqCst))
            .on_half_open(move |_| _ = half_opened.fetch_add(1, Ordering::SeqCst))
            .on_close(move |_| _ = closed.fetch_add(1, Ordering::SeqCst))
    }

    fn counts(&self) -> (usize, usize, usize) {
        (
            self.opened.load(Ordering::SeqCst),
            self.half_opened.load(Ordering::SeqCst),
            self.closed.load(Ordering::SeqCst),
        )
    }
}

/// Memory storage whose reads can be made to panic, to poison a dispatch.
#[derive(Debug)]
struct FlakyStorage {
    inner: Arc<MemoryStorage>,
    panic_counting: AtomicBool,
    panic_clock: AtomicBool,
}

impl FlakyStorage {
    fn new(clock: &ManualClock) -> Self {
        Self {
            inner: clock.storage(),
            panic_counting: AtomicBool::new(false),
            panic_clock: AtomicBool::new(false),
        }
    }
}

impl StorageBackend for FlakyStorage {
    fn record_success(&self, circuit_name: &str, duration: f64) {
        self.inner.record_success(circuit_name, duration);
    }

    fn record_failure(&self, circuit_name: &str, duration: f64) {
        self.inner.record_failure(circuit_name, duration);
    }

    fn success_count(&self, circuit_name: &str, window_seconds: f64) -> usize {
        self.inner.success_count(circuit_name, window_seconds)
    }

    fn failure_count(&self, circuit_name: &str, window_seconds: f64) -> usize {
        assert!(
            !self.panic_counting.load(Ordering::SeqCst),
            "storage unavailable"
        );
        self.inner.failure_count(circuit_name, window_seconds)
    }

    fn clear(&self, circuit_name: &str) {
        self.inner.clear(circuit_name);
    }

    fn clear_all(&self) {
        self.inner.clear_all();
    }

    fn event_log(&self, circuit_name: &str, limit: usize) -> Vec<Event> {
        self.inner.event_log(circuit_name, limit)
    }

    fn monotonic_time(&self) -> f64 {
        assert!(
            !self.panic_clock.load(Ordering::SeqCst),
            "clock unavailable"
        );
        self.inner.monotonic_time()
    }
}

fn fail(circuit: &mut CircuitBreaker, times: usize) {
    for _ in 0..times {
        let _ = circuit.call(|| Err::<(), _>("boom"));
    }
}

fn consecutive_successes(circuit: &CircuitBreaker) -> Option<usize> {
    circuit
        .machine
        .half_open_data()
        .map(|data| data.consecutive_successes)
}

#[test]
fn new_circuit_starts_closed() {
    let circuit = CircuitBreaker::new("test".into(), Config::default());

    assert!(circuit.is_closed());
    assert!(!circuit.is_open());
    assert_eq!(circuit.state_name(), "Closed");
}

#[test]
fn opens_once_failure_threshold_is_reached() {
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(3).build();

    fail(&mut circuit, 2);
    assert!(circuit.is_closed());

    fail(&mut circuit, 1);
    assert!(circuit.is_open());
}

#[test]
fn reset_closes_and_clears_events() {
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(2).build();
    fail(&mut circuit, 2);
    assert!(circuit.is_open());

    circuit.reset();

    assert!(circuit.is_closed());
    assert_eq!(circuit.context.storage.failure_count("test", 60.0), 0);
}

#[test]
fn machine_trip_guard_waits_for_failure_threshold() {
    let storage = Arc::new(MemoryStorage::new());
    let config = Config {
        failure_threshold: Some(3),
        ..Config::default()
    };
    let mut machine = DynamicCircuit::new(context(config, storage.clone()));

    assert_matches!(
        machine.handle(CircuitEvent::Trip),
        Err(DynamicError::GuardFailed {
            guard: "should_open",
            ..
        })
    );

    for _ in 0..3 {
        storage.record_failure("test", 0.1);
    }

    assert_matches!(machine.handle(CircuitEvent::Trip), Ok(_));
    assert_eq!(machine.current_state(), CircuitState::Open);
}

#[test]
fn machine_half_opens_exactly_at_timeout_without_jitter() {
    let clock = ManualClock::starting_at(100);
    let storage = clock.storage();
    let config = Config {
        failure_threshold: Some(2),
        half_open_timeout_secs: 1.0,
        ..Config::default()
    };
    storage.record_failure("test", 0.1);
    storage.record_failure("test", 0.1);
    let mut machine = DynamicCircuit::new(context(config, storage));
    trip(&mut machine);
    assert_matches!(
        machine.open_data(),
        Some(OpenData {
            opened_at: 100.0,
            retry_at: 101.0,
        })
    );

    clock.advance(Duration::from_millis(999));
    assert_matches!(
        machine.handle(CircuitEvent::AttemptReset),
        Err(DynamicError::GuardFailed {
            guard: "timeout_elapsed",
            ..
        })
    );

    clock.advance(Duration::from_millis(1));
    assert_matches!(machine.handle(CircuitEvent::AttemptReset), Ok(_));
    assert_eq!(machine.current_state(), CircuitState::HalfOpen);
    assert_matches!(
        machine.half_open_data(),
        Some(HalfOpenData {
            consecutive_successes: 0,
            in_flight: 0,
        })
    );
}

#[test]
fn machine_close_guard_requires_success_threshold() {
    let clock = ManualClock::starting_at(100);
    let storage = clock.storage();
    let config = Config {
        failure_threshold: Some(1),
        half_open_timeout_secs: 1.0,
        success_threshold: 2,
        ..Config::default()
    };
    storage.record_failure("test", 0.1);
    let mut machine = DynamicCircuit::new(context(config, storage));
    trip(&mut machine);
    clock.advance(Duration::from_secs(1));
    machine
        .handle(CircuitEvent::AttemptReset)
        .expect("timeout elapsed");

    assert_matches!(
        machine.handle(CircuitEvent::Close),
        Err(DynamicError::GuardFailed {
            guard: "should_close",
            ..
        })
    );

    machine
        .half_open_data_mut()
        .expect("HalfOpen carries HalfOpenData")
        .consecutive_successes = 2;
    assert_matches!(machine.handle(CircuitEvent::Close), Ok(_));
    assert_eq!(machine.current_state(), CircuitState::Closed);
}

#[test]
fn jitter_is_drawn_once_per_open_cycle() {
    let clock = ManualClock::starting_at(100);
    let storage = clock.storage();
    let config = Config {
        failure_threshold: Some(1),
        half_open_timeout_secs: 1.0,
        jitter_factor: 0.5,
        ..Config::default()
    };
    storage.record_failure("test", 0.1);
    let mut machine = DynamicCircuit::new(context(config, storage));
    trip(&mut machine);

    let Some(&OpenData {
        opened_at,
        retry_at,
    }) = machine.open_data()
    else {
        panic!("Open carries OpenData");
    };
    assert_eq!(opened_at, 100.0);
    assert_matches!(retry_at - opened_at, 0.5..=1.0);
    let cooldown = Duration::from_millis(((retry_at - opened_at) * 1000.0).round() as u64);

    // Just short of retry_at, every check agrees: the delay is not redrawn.
    clock.advance(cooldown - Duration::from_millis(1));
    for _ in 0..64 {
        assert_matches!(
            machine.handle(CircuitEvent::AttemptReset),
            Err(DynamicError::GuardFailed { .. })
        );
    }

    clock.advance(Duration::from_millis(1));
    assert_matches!(machine.handle(CircuitEvent::AttemptReset), Ok(_));
}

#[test]
fn jittered_delay_stays_within_bounds() {
    let config = Config {
        half_open_timeout_secs: 1.0,
        jitter_factor: 0.25,
        ..Config::default()
    };

    for _ in 0..50 {
        assert_matches!(config.half_open_delay_secs(), 0.75..=1.0);
    }
}

#[test]
fn jitter_varies_the_delay() {
    let config = Config {
        half_open_timeout_secs: 1.0,
        jitter_factor: 0.5,
        ..Config::default()
    };

    let first = config.half_open_delay_secs();
    assert!(
        (0..20).any(|_| config.half_open_delay_secs() != first),
        "50% jitter produced a constant delay of {first}s"
    );
}

#[test]
fn zero_jitter_uses_the_exact_timeout() {
    let config = Config {
        half_open_timeout_secs: 1.0,
        jitter_factor: 0.0,
        ..Config::default()
    };

    for _ in 0..10 {
        assert_eq!(config.half_open_delay_secs(), 1.0);
    }
}

#[test]
fn builder_sets_jitter_factor() {
    let circuit = CircuitBreaker::builder("test").jitter_factor(0.5).build();

    assert_eq!(circuit.context.config.jitter_factor, 0.5);
}

#[test]
fn fallback_runs_when_open() {
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(2).build();
    fail(&mut circuit, 2);
    assert!(circuit.is_open());

    let result = circuit.call((
        || Err::<String, _>("should not execute"),
        CallOptions::new().with_fallback(|ctx| {
            assert_matches!(
                ctx,
                FallbackContext { circuit_name, state: "Open", .. } if &**circuit_name == "test"
            );
            Ok("fallback response".to_string())
        }),
    ));

    assert_matches!(result.as_deref(), Ok("fallback response"));
}

#[test]
fn fallback_errors_propagate_as_execution() {
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(1).build();
    fail(&mut circuit, 1);
    assert!(circuit.is_open());

    let result = circuit.call((
        || Ok::<String, _>("should not execute".to_string()),
        CallOptions::new().with_fallback(|_ctx| Err::<String, _>("fallback error")),
    ));

    assert_matches!(result, Err(CircuitError::Execution("fallback error")));
}

#[test]
fn rate_threshold_waits_for_minimum_calls() {
    let mut circuit = CircuitBreaker::builder("test")
        .disable_failure_threshold()
        .failure_rate(0.5)
        .minimum_calls(10)
        .build();

    // Alternate success/failure: 4 of the first 9 calls fail.
    for call in 0..9 {
        let _ = if call % 2 == 0 {
            circuit.call(|| Ok::<(), &str>(()))
        } else {
            circuit.call(|| Err::<(), &str>("error"))
        };
        assert!(
            circuit.is_closed(),
            "opened after {} calls, below minimum_calls",
            call + 1
        );
    }

    // 10th call: 5 failures out of 10 reaches the 50% rate.
    fail(&mut circuit, 1);
    assert!(circuit.is_open(), "did not open at the rate threshold");
}

#[test]
fn absolute_threshold_trips_before_rate_is_evaluated() {
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(3)
        .failure_rate(0.8)
        .minimum_calls(10)
        .build();

    fail(&mut circuit, 2);
    assert!(circuit.is_closed());

    fail(&mut circuit, 1);
    assert!(circuit.is_open(), "did not open at the absolute threshold");
}

#[test]
fn minimum_calls_prevents_premature_trip() {
    let mut circuit = CircuitBreaker::builder("test")
        .disable_failure_threshold()
        .failure_rate(0.5)
        .minimum_calls(20)
        .build();

    // 100% failure rate, but only half of minimum_calls.
    fail(&mut circuit, 10);

    assert!(circuit.is_closed(), "opened before reaching minimum_calls");
}

#[test]
fn classifier_filters_which_errors_trip() {
    // Trip on "server" errors only; unknown error types still trip.
    let classifier = Arc::new(PredicateClassifier::new(|ctx| {
        ctx.error
            .downcast_ref::<&str>()
            .is_none_or(|error| error.contains("server"))
    }));
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .failure_classifier(classifier)
        .build();

    for _ in 0..5 {
        let _ = circuit.call(|| Err::<(), _>("client_error"));
    }
    assert!(circuit.is_closed(), "tripped on filtered errors");
    assert_eq!(circuit.context.storage.failure_count("test", 60.0), 0);

    let _ = circuit.call(|| Err::<(), _>("server_error_1"));
    let _ = circuit.call(|| Err::<(), _>("server_error_2"));
    assert!(circuit.is_open(), "did not trip on server errors");
}

#[test]
fn classifier_sees_call_duration() {
    let classifier = Arc::new(PredicateClassifier::new(|ctx| ctx.duration > 0.5));
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .failure_classifier(classifier)
        .build();

    // Test calls finish in well under 0.5s.
    fail(&mut circuit, 10);

    assert!(circuit.is_closed(), "tripped on fast errors");
}

#[test]
fn classifier_downcasts_custom_error_types() {
    #[derive(Debug)]
    enum ApiError {
        Client(u16),
        Server(u16),
    }

    let classifier = Arc::new(PredicateClassifier::new(|ctx| {
        ctx.error
            .downcast_ref::<ApiError>()
            .is_none_or(|error| match error {
                ApiError::Client(status) | ApiError::Server(status) => *status >= 500,
            })
    }));
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .failure_classifier(classifier)
        .build();

    for _ in 0..10 {
        let _ = circuit.call(|| Err::<(), _>(ApiError::Client(404)));
    }
    assert!(circuit.is_closed(), "4xx tripped the circuit");

    let _ = circuit.call(|| Err::<(), _>(ApiError::Server(500)));
    let _ = circuit.call(|| Err::<(), _>(ApiError::Server(503)));
    assert!(circuit.is_open(), "5xx did not trip the circuit");
}

#[test]
fn bulkhead_permit_is_released_after_each_call() {
    let mut circuit = CircuitBreaker::builder("test")
        .max_concurrency(1)
        .failure_threshold(10)
        .build();
    let bulkhead = circuit
        .context
        .bulkhead
        .clone()
        .expect("max_concurrency installs a bulkhead");

    assert_matches!(circuit.call(|| Ok::<_, &str>("first")), Ok("first"));
    assert_eq!(bulkhead.acquired(), 0);

    assert_matches!(
        circuit.call(|| Err::<(), _>("failed")),
        Err(CircuitError::Execution("failed"))
    );
    assert_eq!(bulkhead.acquired(), 0);

    assert_matches!(circuit.call(|| Ok::<_, &str>("second")), Ok("second"));
}

#[test]
fn unbounded_without_bulkhead() {
    let mut circuit = CircuitBreaker::builder("test").build();
    assert_matches!(circuit.context.bulkhead, None);

    for _ in 0..100 {
        assert_matches!(circuit.call(|| Ok::<_, &str>(())), Ok(()));
    }
}

#[test]
fn bulkhead_full_reports_circuit_and_limit() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(2));
    let mut circuit = CircuitBreaker::builder("test").build();
    circuit.context.bulkhead = Some(bulkhead.clone());

    let held = [bulkhead.try_acquire(), bulkhead.try_acquire()];
    assert_matches!(held, [Some(_), Some(_)]);

    assert_matches!(
        circuit.call(|| Ok::<_, &str>("rejected")),
        Err(CircuitError::BulkheadFull { circuit: name, limit: 2 }) if &*name == "test"
    );

    drop(held);
    assert_matches!(circuit.call(|| Ok::<_, &str>("admitted")), Ok("admitted"));
}

#[test]
fn open_circuit_rejects_despite_bulkhead_capacity() {
    let mut circuit = CircuitBreaker::builder("test")
        .max_concurrency(5)
        .failure_threshold(3)
        .build();
    assert_matches!(circuit.call(|| Ok::<_, &str>(())), Ok(()));

    fail(&mut circuit, 3);
    assert!(circuit.is_open());

    assert_matches!(
        circuit.call(|| Ok::<_, &str>("rejected")),
        Err(CircuitError::Open { .. })
    );
}

#[test]
fn open_fallback_releases_bulkhead_permit() {
    let bulkhead = Arc::new(BulkheadSemaphore::new(1));
    let mut circuit = CircuitBreaker::builder("test").failure_threshold(1).build();
    circuit.context.bulkhead = Some(bulkhead.clone());
    fail(&mut circuit, 1);
    assert!(circuit.is_open());

    // The permit must be released before the fallback runs so the fallback
    // body can acquire it itself.
    let result = circuit.call((
        || Ok::<bool, &str>(false),
        CallOptions::new().with_fallback(move |_ctx| Ok(bulkhead.try_acquire().is_some())),
    ));

    assert_matches!(result, Ok(true), "fallback could not acquire the permit");
}

#[test]
fn check_and_trip_stamps_opened_at_and_fires_on_open() {
    let clock = ManualClock::starting_at(100);
    let opened = Arc::new(AtomicBool::new(false));
    let on_open = Arc::clone(&opened);
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(1)
        .storage(clock.storage())
        .on_open(move |_name| on_open.store(true, Ordering::SeqCst))
        .build();

    circuit.record_failure(0.1);

    assert!(circuit.check_and_trip(), "trip should succeed");
    assert!(circuit.is_open());
    assert_matches!(
        circuit.machine.open_data(),
        Some(OpenData {
            opened_at: 100.0,
            retry_at: 130.0,
        })
    );
    assert!(opened.load(Ordering::SeqCst), "on_open did not fire");
    assert!(
        !circuit.check_and_trip(),
        "an open circuit cannot trip again"
    );
}

#[test]
fn half_open_failure_resets_consecutive_successes() {
    let clock = ManualClock::starting_at(100);
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .failure_window_secs(1.0)
        .half_open_timeout_secs(5.0)
        .success_threshold(2)
        .storage(clock.storage())
        .build();
    fail(&mut circuit, 2);
    assert!(circuit.is_open());

    // Cooldown elapses and the opening failures age out of the window.
    clock.advance(Duration::from_secs(5));

    assert_matches!(circuit.call(|| Ok::<_, &str>("ok")), Ok("ok"));
    assert_eq!(circuit.state_name(), "HalfOpen");
    assert_eq!(consecutive_successes(&circuit), Some(1));

    // One failure is below the threshold: stay HalfOpen, restart the count.
    fail(&mut circuit, 1);
    assert_eq!(circuit.state_name(), "HalfOpen");
    assert_eq!(consecutive_successes(&circuit), Some(0));

    assert_matches!(circuit.call(|| Ok::<_, &str>("ok")), Ok("ok"));
    assert_eq!(consecutive_successes(&circuit), Some(1));
}

#[test]
fn panicking_probe_releases_half_open_slot() {
    let clock = ManualClock::starting_at(100);
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(1.0)
        .success_threshold(1)
        .storage(clock.storage())
        .build();
    fail(&mut circuit, 1);
    clock.advance(Duration::from_secs(1));

    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        circuit.call(|| -> Result<(), &'static str> { panic!("boom") })
    }));
    assert_matches!(panicked, Err(_), "probe should have panicked");
    assert_matches!(
        circuit.machine.half_open_data(),
        Some(HalfOpenData { in_flight: 0, .. })
    );

    assert_matches!(
        circuit.call(|| Ok::<_, &str>("ok")),
        Ok("ok"),
        "probe slot leaked after panic"
    );
    assert!(circuit.is_closed(), "circuit should recover and close");
}

#[test]
fn callbacks_fire_once_per_transition() {
    let clock = ManualClock::starting_at(100);
    let transitions = Transitions::default();
    let mut circuit = transitions
        .attach(CircuitBreaker::builder("test"))
        .failure_threshold(1)
        .half_open_timeout_secs(1.0)
        .success_threshold(1)
        .storage(clock.storage())
        .build();

    fail(&mut circuit, 1);
    assert_eq!(transitions.counts(), (1, 0, 0));

    // Rejected calls do not re-fire on_open.
    assert_matches!(
        circuit.call(|| Ok::<_, &str>(())),
        Err(CircuitError::Open { .. })
    );
    assert_eq!(transitions.counts(), (1, 0, 0));

    clock.advance(Duration::from_secs(1));
    assert_matches!(circuit.call(|| Ok::<_, &str>(())), Ok(()));
    assert_eq!(transitions.counts(), (1, 1, 1));

    // reset is a transition, but not a recovery: no callbacks.
    fail(&mut circuit, 1);
    circuit.reset();
    assert!(circuit.is_closed());
    assert_eq!(transitions.counts(), (2, 1, 1));
}

#[test]
fn failed_probe_reopens_with_a_fresh_cooldown() {
    let clock = ManualClock::starting_at(100);
    let transitions = Transitions::default();
    let mut circuit = transitions
        .attach(CircuitBreaker::builder("test"))
        .failure_threshold(1)
        .half_open_timeout_secs(10.0)
        .success_threshold(1)
        .storage(clock.storage())
        .build();
    fail(&mut circuit, 1);

    clock.advance(Duration::from_secs(10));
    fail(&mut circuit, 1);

    assert!(circuit.is_open());
    assert_matches!(
        circuit.machine.open_data(),
        Some(OpenData {
            opened_at: 110.0,
            retry_at: 120.0,
        })
    );
    assert_eq!(transitions.counts(), (2, 1, 0));
}

#[test]
fn reset_advances_the_state_epoch() {
    let mut circuit = CircuitBreaker::builder("test").build();
    let before = circuit.state_epoch();

    circuit.reset();

    assert_eq!(circuit.state_epoch(), before + 1);
    assert!(circuit.is_closed());
}

#[test]
fn recovers_from_a_dispatch_poisoned_in_closed() {
    let clock = ManualClock::starting_at(100);
    let storage = Arc::new(FlakyStorage::new(&clock));
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(2)
        .storage(storage.clone())
        .build();
    let epoch = circuit.state_epoch();

    // The trip guard panics mid-dispatch and poisons the machine.
    storage.panic_counting.store(true, Ordering::SeqCst);
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        circuit.call(|| Err::<(), _>("boom"))
    }));
    assert_matches!(panicked, Err(_));
    assert!(circuit.machine.is_poisoned());
    storage.panic_counting.store(false, Ordering::SeqCst);

    // The next call rebuilds from the last committed state, Closed.
    assert_matches!(circuit.call(|| Ok::<_, &str>("ok")), Ok("ok"));
    assert!(!circuit.machine.is_poisoned());
    assert!(circuit.is_closed());
    assert!(
        circuit.state_epoch() > epoch,
        "rebuild must fence old permits"
    );

    // ...and the rebuilt machine still trips.
    fail(&mut circuit, 1);
    assert!(circuit.is_open());
}

#[test]
fn recovers_from_a_dispatch_poisoned_in_open_by_restarting_cooldown() {
    let clock = ManualClock::starting_at(100);
    let storage = Arc::new(FlakyStorage::new(&clock));
    let mut circuit = CircuitBreaker::builder("test")
        .failure_threshold(1)
        .half_open_timeout_secs(10.0)
        .storage(storage.clone())
        .build();
    fail(&mut circuit, 1);
    clock.advance(Duration::from_secs(10));

    // The cooldown guard panics while deciding Open -> HalfOpen.
    storage.panic_clock.store(true, Ordering::SeqCst);
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        circuit.call(|| Ok::<_, &str>("probe"))
    }));
    assert_matches!(panicked, Err(_));
    assert!(circuit.machine.is_poisoned());
    storage.panic_clock.store(false, Ordering::SeqCst);

    // Rebuilt as Open with a cooldown restarted from now, not half-opened.
    assert_matches!(
        circuit.call(|| Ok::<_, &str>("probe")),
        Err(CircuitError::Open {
            opened_at: 110.0,
            ..
        })
    );
    assert_matches!(
        circuit.machine.open_data(),
        Some(OpenData {
            retry_at: 120.0,
            ..
        })
    );
}

#[test]
fn state_graph_validates() {
    assert_matches!(Circuit::<Closed>::schema().validate().as_slice(), []);
}
