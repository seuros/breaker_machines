use super::*;

fn nz(n: u32) -> NonZeroU32 {
    NonZeroU32::new(n).expect("test counts are positive")
}

#[test]
fn threshold_needs_a_count_or_a_valid_rate() {
    assert_eq!(Threshold::new(None, None, 0), None);
    for rate in [0.0, -0.1, 1.000_001, f64::NAN, f64::INFINITY] {
        assert_eq!(Threshold::new(None, Some(rate), 1), None, "rate {rate}");
        assert_eq!(
            Threshold::new(Some(nz(3)), Some(rate), 1),
            None,
            "rate {rate}"
        );
    }
    let threshold = Threshold::new(Some(nz(3)), Some(1.0), 4).expect("valid");
    assert_eq!(threshold.count(), Some(nz(3)));
    assert_eq!(threshold.rate(), Some(1.0));
    assert_eq!(threshold.minimum_calls(), 4);
}

#[test]
fn a_threshold_validates_at_compile_time() {
    const COUNT: Threshold = match Threshold::new(NonZeroU32::new(5), None, 0) {
        Some(threshold) => threshold,
        None => panic!("a valid threshold"),
    };
    const NOTHING: Option<Threshold> = Threshold::new(None, None, 0);
    const NAN: Option<Threshold> = Threshold::new(NonZeroU32::new(5), Some(f64::NAN), 0);
    assert_eq!(COUNT.count(), NonZeroU32::new(5));
    assert_eq!((NOTHING, NAN), (None, None));
}

#[test]
fn threshold_judges_count_and_rate() {
    let count = Threshold::new(Some(nz(3)), None, 0).expect("valid");
    assert!(!count.exceeded(2, 0));
    assert!(count.exceeded(3, 100));

    let rate = Threshold::new(None, Some(0.5), 4).expect("valid");
    assert!(!rate.exceeded(0, 0), "an empty window never trips");
    assert!(
        !rate.exceeded(3, 0),
        "below minimum_calls the rate is not judged"
    );
    assert!(rate.exceeded(2, 2));
    assert!(!rate.exceeded(1, 3));

    let either = Threshold::new(Some(nz(10)), Some(0.5), 4).expect("valid");
    assert!(either.exceeded(10, 1000), "the count trips before the rate");
    assert!(either.exceeded(3, 1));
}

#[test]
fn recovery_and_policy_validate() {
    assert_eq!(
        Recovery::new(Duration::from_secs(1), 1.5, nz(1), nz(1)),
        None
    );
    assert_eq!(
        Recovery::new(Duration::from_secs(1), -0.1, nz(1), nz(1)),
        None
    );
    let recovery = Recovery::new(Duration::from_secs(30), 0.25, nz(2), nz(3)).expect("valid");
    assert_eq!(recovery.cooldown().span(), Duration::from_secs(30));
    assert_eq!(recovery.cooldown().jitter(), 0.25);
    assert_eq!(recovery.success_threshold(), nz(2));
    assert_eq!(recovery.half_open_calls(), nz(3));

    let threshold = Threshold::new(Some(nz(5)), None, 0).expect("valid");
    assert_eq!(Policy::new(threshold, Duration::ZERO, recovery, None), None);
    let policy =
        Policy::new(threshold, Duration::from_secs(60), recovery, Some(nz(8))).expect("valid");
    assert_eq!(policy.threshold(), threshold);
    assert_eq!(policy.window(), Duration::from_secs(60));
    assert_eq!(policy.recovery(), recovery);
    assert_eq!(policy.max_concurrent(), Some(nz(8)));
}
