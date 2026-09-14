use super::*;

#[test]
fn test_memory_storage_record_and_count() {
    let storage = MemoryStorage::new();

    storage.record_success("test_circuit", 0.1);
    storage.record_success("test_circuit", 0.2);
    storage.record_failure("test_circuit", 0.5);

    assert_eq!(storage.success_count("test_circuit", 60.0), 2);
    assert_eq!(storage.failure_count("test_circuit", 60.0), 1);
}

#[test]
fn test_memory_storage_clear() {
    let storage = MemoryStorage::new();

    storage.record_success("test_circuit", 0.1);
    assert_eq!(storage.success_count("test_circuit", 60.0), 1);

    storage.clear("test_circuit");
    assert_eq!(storage.success_count("test_circuit", 60.0), 0);
}

#[test]
fn test_memory_storage_event_log() {
    let storage = MemoryStorage::new();

    storage.record_success("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.2);
    storage.record_success("test_circuit", 0.3);

    let log = storage.event_log("test_circuit", 10);
    assert_eq!(log.len(), 3);
    assert_eq!(log[0].kind, EventKind::Success);
    assert_eq!(log[1].kind, EventKind::Failure);
    assert_eq!(log[2].kind, EventKind::Success);
}

#[test]
fn test_memory_storage_max_events_cleanup() {
    let storage = MemoryStorage::with_max_events(100);

    for i in 0..150 {
        storage.record_success("test_circuit", i as f64 * 0.01);
    }

    let circuits = storage.circuits.read();
    let circuit_events = &circuits.get("test_circuit").unwrap().events;

    assert!(circuit_events.len() <= 100);
}

#[test]
fn test_memory_storage_small_max_events() {
    let storage = MemoryStorage::with_max_events(5);

    for i in 0..20 {
        storage.record_success("test_circuit", i as f64 * 0.01);
    }

    let circuits = storage.circuits.read();
    let circuit_events = &circuits.get("test_circuit").unwrap().events;

    assert!(
        circuit_events.len() <= 5,
        "Expected <= 5 events, got {}",
        circuit_events.len()
    );
}

#[test]
fn test_memory_storage_monotonic_time() {
    let storage = MemoryStorage::new();

    storage.record_success("test_circuit", 0.1);
    let time1 = storage.monotonic_time();

    std::thread::sleep(std::time::Duration::from_millis(10));

    storage.record_success("test_circuit", 0.2);
    let time2 = storage.monotonic_time();

    assert!(time2 > time1);
    assert_eq!(storage.success_count("test_circuit", 1.0), 2);
}

#[test]
fn test_null_storage_discards_events() {
    let storage = NullStorage::new();

    storage.record_success("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.2);

    assert_eq!(storage.success_count("test_circuit", 60.0), 0);
    assert_eq!(storage.failure_count("test_circuit", 60.0), 0);
}

#[test]
fn test_null_storage_empty_event_log() {
    let storage = NullStorage::new();

    storage.record_success("test_circuit", 0.1);
    storage.record_failure("test_circuit", 0.2);

    let log = storage.event_log("test_circuit", 10);
    assert_eq!(log.len(), 0);
}

#[test]
fn test_null_storage_clear_operations() {
    let storage = NullStorage::new();

    storage.clear("test_circuit");
    storage.clear_all();

    assert_eq!(storage.success_count("test_circuit", 60.0), 0);
}

#[test]
fn test_null_storage_monotonic_time() {
    let storage = NullStorage::new();

    let time1 = storage.monotonic_time();
    std::thread::sleep(std::time::Duration::from_millis(10));
    let time2 = storage.monotonic_time();

    assert!(time2 > time1);
}

#[test]
fn test_null_storage_with_circuit_breaker() {
    use std::sync::Arc;

    let storage = Arc::new(NullStorage::new());
    let mut circuit = crate::CircuitBreaker::builder("test")
        .storage(storage)
        .failure_threshold(3)
        .build();

    let _ = circuit.call(|| Err::<(), _>("error 1"));
    let _ = circuit.call(|| Err::<(), _>("error 2"));
    let _ = circuit.call(|| Err::<(), _>("error 3"));

    assert!(circuit.is_closed());
    assert!(!circuit.is_open());
}
