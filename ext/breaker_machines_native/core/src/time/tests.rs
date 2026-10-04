use super::*;
use core::time::Duration;

#[test]
fn system_clock_is_monotonic() {
    let clock = SystemClock::new();
    let a = clock.now_secs();
    std::thread::sleep(Duration::from_millis(2));
    let b = clock.now_secs();
    assert!(b >= a, "clock went backwards: {a} -> {b}");
}

#[test]
fn zero_clock_never_moves() {
    assert_eq!(ZeroClock.now_secs(), 0.0);
    assert_eq!(ZeroClock.now_secs(), 0.0);
}
