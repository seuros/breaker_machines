use super::*;
use crate::test_support::ManualClock;
use core::assert_matches;
use core::time::Duration;

fn retained_events(storage: &MemoryStorage) -> usize {
    storage
        .circuits
        .read()
        .get("test_circuit")
        .map_or(0, |circuit| circuit.events.len())
}

#[test]
fn memory_storage_counts_by_kind() {
    let storage = MemoryStorage::new();

    storage.record_success("test_circuit", 0.1);
    storage.record_success("test_circuit", 0.2);
    storage.record_failure("test_circuit", 0.5);

    assert_eq!(storage.success_count("test_circuit", 60.0), 2);
    assert_eq!(storage.failure_count("test_circuit", 60.0), 1);
    assert_eq!(storage.success_count("other_circuit", 60.0), 0);
}

#[test]
fn memory_storage_clear_drops_one_circuit() {
    let storage = MemoryStorage::new();
    storage.record_success("test_circuit", 0.1);
    storage.record_success("other_circuit", 0.1);

    storage.clear("test_circuit");

    assert_eq!(storage.success_count("test_circuit", 60.0), 0);
    assert_eq!(storage.success_count("other_circuit", 60.0), 1);

    storage.clear_all();
    assert_eq!(storage.success_count("other_circuit", 60.0), 0);
}

#[test]
fn memory_storage_event_log_keeps_order_and_limit() {
    let storage = MemoryStorage::new();
    storage.record_success("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.2);
    storage.record_success("test_circuit", 0.3);

    let kinds = |limit| -> Vec<EventKind> {
        storage
            .event_log("test_circuit", limit)
            .iter()
            .map(|event| event.kind)
            .collect()
    };

    assert_eq!(
        kinds(10),
        [EventKind::Success, EventKind::Failure, EventKind::Success]
    );
    assert_eq!(kinds(2), [EventKind::Failure, EventKind::Success]);
}

#[test]
fn memory_storage_caps_retained_events() {
    let storage = MemoryStorage::with_max_events(100);
    for i in 0..150 {
        storage.record_success("test_circuit", f64::from(i) * 0.01);
    }

    assert_matches!(retained_events(&storage), 1..=100);
}

#[test]
fn memory_storage_caps_small_limits() {
    let storage = MemoryStorage::with_max_events(5);
    for i in 0..20 {
        storage.record_success("test_circuit", f64::from(i) * 0.01);
    }

    assert_matches!(retained_events(&storage), 1..=5);
}

#[test]
fn memory_storage_window_follows_its_clock() {
    let clock = ManualClock::starting_at(100);
    let storage = MemoryStorage::with_clock(Box::new(clock.clone()));

    storage.record_failure("test_circuit", 0.1);
    clock.advance(Duration::from_secs(2));
    storage.record_failure("test_circuit", 0.1);

    assert_eq!(storage.monotonic_time(), 102.0);
    assert_eq!(storage.failure_count("test_circuit", 1.0), 1);
    assert_eq!(storage.failure_count("test_circuit", 2.0), 2);
}

#[test]
fn memory_storage_system_clock_is_monotonic() {
    let storage = MemoryStorage::new();

    let before = storage.monotonic_time();
    std::thread::sleep(Duration::from_millis(10));

    assert!(storage.monotonic_time() > before);
}

#[test]
fn null_storage_discards_everything() {
    let storage = NullStorage::new();

    storage.record_success("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.2);
    storage.clear("test_circuit");
    storage.clear_all();

    assert_eq!(storage.success_count("test_circuit", 60.0), 0);
    assert_eq!(storage.failure_count("test_circuit", 60.0), 0);
    assert!(storage.event_log("test_circuit", 10).is_empty());
}

#[test]
fn null_storage_time_still_advances() {
    let storage = NullStorage::new();

    let before = storage.monotonic_time();
    std::thread::sleep(Duration::from_millis(10));

    assert!(storage.monotonic_time() > before);
}

#[test]
fn null_storage_never_trips_a_circuit() {
    let mut circuit = crate::CircuitBreaker::builder("test")
        .storage(alloc::sync::Arc::new(NullStorage::new()))
        .failure_threshold(3)
        .build();

    for _ in 0..3 {
        let _ = circuit.call(|| Err::<(), _>("error"));
    }

    assert!(circuit.is_closed());
}
