//! Values read from Ruby and built for it.
//!
//! Every `Threshold`, `Recovery` and `Policy` the binding reads must be
//! exactly this gem's class (a subclass is a `TypeError`); its fields are
//! read from the struct, converted, and the value rebuilt through the core
//! constructor, so a forged value raises before it reaches the core.
use breaker_machines::{Event, Policy, Recovery, Status, Threshold};
use core::num::NonZeroU32;
use magnus::{Error, Ruby, Value, prelude::*};
use matryona_machines::ruby::{
    class_name, duration, exact_fields_with, finite, instant, integer, nanoseconds,
    optional_positive, positive,
};

use crate::classes::classes;
use crate::names::{Outcomes, States};
use matryona_machines::ruby::Symbols;

fn range_error(ruby: &Ruby, message: &'static str) -> Error {
    Error::new(ruby.exception_range_error(), message)
}

fn optional_finite(value: Value, name: &str) -> Result<Option<f64>, Error> {
    if value.is_nil() {
        return Ok(None);
    }
    finite(value, name).map(Some)
}

/// `Threshold::new` of Ruby values, in order.
fn build_threshold(
    ruby: &Ruby,
    count: Value,
    rate: Value,
    minimum_calls: Value,
) -> Result<Threshold, Error> {
    let count = optional_positive::<NonZeroU32>(count, "count")?;
    let rate = optional_finite(rate, "rate")?;
    let minimum_calls = integer::<u32>(minimum_calls, "minimum_calls")?;
    Threshold::new(count, rate, minimum_calls).ok_or_else(|| {
        range_error(
            ruby,
            "threshold needs a count or a rate, and a rate in 0.0 < rate <= 1.0",
        )
    })
}

/// `Recovery::new` of Ruby values, in order.
fn build_recovery(
    ruby: &Ruby,
    cooldown: Value,
    jitter: Value,
    success_threshold: Value,
    half_open_calls: Value,
) -> Result<Recovery, Error> {
    let cooldown = duration(cooldown, "cooldown")?;
    let jitter = finite(jitter, "jitter")?;
    let success_threshold = positive::<NonZeroU32>(success_threshold, "success_threshold")?;
    let half_open_calls = positive::<NonZeroU32>(half_open_calls, "half_open_calls")?;
    Recovery::new(cooldown, jitter, success_threshold, half_open_calls)
        .ok_or_else(|| range_error(ruby, "jitter must be in 0.0..=1.0"))
}

/// `Policy::new` of Ruby values, in order.
fn build_policy(
    ruby: &Ruby,
    threshold: Value,
    window: Value,
    recovery: Value,
    max_concurrent: Value,
) -> Result<Policy, Error> {
    let threshold = read_threshold(ruby, threshold)?;
    let window = duration(window, "window")?;
    let recovery = read_recovery(ruby, recovery)?;
    let max_concurrent = optional_positive::<NonZeroU32>(max_concurrent, "max_concurrent")?;
    Policy::new(threshold, window, recovery, max_concurrent)
        .ok_or_else(|| range_error(ruby, "window must be positive"))
}

fn read_threshold(ruby: &Ruby, value: Value) -> Result<Threshold, Error> {
    let class = classes(ruby)?.threshold.get(ruby);
    let [count, rate, minimum_calls] = exact_fields_with::<3>(ruby, value, class, || {
        format!(
            "threshold must be a BreakerMachines::Threshold, not {}",
            class_name(value)
        )
    })?;
    build_threshold(ruby, count, rate, minimum_calls)
}

fn read_recovery(ruby: &Ruby, value: Value) -> Result<Recovery, Error> {
    let class = classes(ruby)?.recovery.get(ruby);
    let [cooldown, jitter, success, probes] = exact_fields_with::<4>(ruby, value, class, || {
        format!(
            "recovery must be a BreakerMachines::Recovery, not {}",
            class_name(value)
        )
    })?;
    build_recovery(ruby, cooldown, jitter, success, probes)
}

/// A policy as the core's: exactly a `BreakerMachines::Policy`.
pub fn policy(ruby: &Ruby, value: Value) -> Result<Policy, Error> {
    let class = classes(ruby)?.policy.get(ruby);
    let [threshold, window, recovery, max] = exact_fields_with::<4>(ruby, value, class, || {
        format!(
            "policy must be a BreakerMachines::Policy, not {}",
            class_name(value)
        )
    })?;
    build_policy(ruby, threshold, window, recovery, max)
}

/// `BreakerMachines::Policy` of `policy`, built by the classes' `new`.
pub fn policy_object(ruby: &Ruby, policy: Policy) -> Result<Value, Error> {
    let classes = classes(ruby)?;
    let threshold = policy.threshold();
    let threshold = classes.threshold.get(ruby).funcall::<_, _, Value>(
        "new",
        (
            threshold.count().map(NonZeroU32::get),
            threshold.rate(),
            threshold.minimum_calls(),
        ),
    )?;
    let recovery = policy.recovery();
    let recovery = classes.recovery.get(ruby).funcall::<_, _, Value>(
        "new",
        (
            nanoseconds(ruby, recovery.cooldown().span()),
            recovery.cooldown().jitter(),
            recovery.success_threshold().get(),
            recovery.half_open_calls().get(),
        ),
    )?;
    classes.policy.get(ruby).funcall(
        "new",
        (
            threshold,
            nanoseconds(ruby, policy.window()),
            recovery,
            policy.max_concurrent().map(NonZeroU32::get),
        ),
    )
}

/// `BreakerMachines::Event` of `event`, built by its `new`.
pub fn event_object(ruby: &Ruby, event: Event) -> Result<Value, Error> {
    classes(ruby)?.event.get(ruby).funcall(
        "new",
        (
            nanoseconds(ruby, event.at),
            Outcomes::symbol(ruby, event.outcome),
            nanoseconds(ruby, event.took),
        ),
    )
}

/// `BreakerMachines.native_threshold`: what `Threshold.new` validates.
pub fn validate_threshold(
    ruby: &Ruby,
    count: Value,
    rate: Value,
    minimum_calls: Value,
) -> Result<(), Error> {
    build_threshold(ruby, count, rate, minimum_calls).map(drop)
}

/// `BreakerMachines.native_recovery`: what `Recovery.new` validates.
pub fn validate_recovery(
    ruby: &Ruby,
    cooldown: Value,
    jitter: Value,
    success_threshold: Value,
    half_open_calls: Value,
) -> Result<(), Error> {
    build_recovery(ruby, cooldown, jitter, success_threshold, half_open_calls).map(drop)
}

/// `BreakerMachines.native_policy`: what `Policy.new` validates.
pub fn validate_policy(
    ruby: &Ruby,
    threshold: Value,
    window: Value,
    recovery: Value,
    max_concurrent: Value,
) -> Result<(), Error> {
    build_policy(ruby, threshold, window, recovery, max_concurrent).map(drop)
}

fn optional_duration(value: Value, name: &str) -> Result<Option<core::time::Duration>, Error> {
    if value.is_nil() {
        return Ok(None);
    }
    instant(value, name).map(Some)
}

/// `Status::new` of Ruby values, in order.
fn build_status(
    ruby: &Ruby,
    state: Value,
    opened_at: Value,
    retry_at: Value,
) -> Result<Status, Error> {
    let state = States::parse(ruby, state)?;
    let opened_at = optional_duration(opened_at, "opened_at")?;
    let retry_at = optional_duration(retry_at, "retry_at")?;
    Status::new(state, opened_at, retry_at).ok_or_else(|| {
        range_error(
            ruby,
            "an open status needs opened_at <= retry_at; closed and half-open ones neither",
        )
    })
}

/// A status as the core's: exactly a `BreakerMachines::Status`.
pub fn status(ruby: &Ruby, value: Value) -> Result<Status, Error> {
    let class = classes(ruby)?.status.get(ruby);
    let [state, opened_at, retry_at] = exact_fields_with::<3>(ruby, value, class, || {
        format!(
            "status must be a BreakerMachines::Status, not {}",
            class_name(value)
        )
    })?;
    build_status(ruby, state, opened_at, retry_at)
}

/// `BreakerMachines::Status` of `status`, built by its `new`.
pub fn status_object(ruby: &Ruby, status: Status) -> Result<Value, Error> {
    classes(ruby)?.status.get(ruby).funcall(
        "new",
        (
            States::symbol(ruby, status.state()),
            status.opened_at().map(|at| nanoseconds(ruby, at)),
            status.retry_at().map(|at| nanoseconds(ruby, at)),
        ),
    )
}

/// `BreakerMachines.native_status`: what `Status.new` validates.
pub fn validate_status(
    ruby: &Ruby,
    state: Value,
    opened_at: Value,
    retry_at: Value,
) -> Result<(), Error> {
    build_status(ruby, state, opened_at, retry_at).map(drop)
}

/// `BreakerMachines.native_event`: what `Event.new` validates.
pub fn validate_event(ruby: &Ruby, at: Value, outcome: Value, took: Value) -> Result<(), Error> {
    instant(at, "at")?;
    Outcomes::parse(ruby, outcome)?;
    instant(took, "took").map(drop)
}
