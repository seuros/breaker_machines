# breaker-machines

> The circuit breaker that went where no Ruby has gone before! ⭐

Circuit breaker decisions with no clock, no allocation and no `unsafe`, and a
`std` runtime that guards closures and futures with them. The decision core
of the [breaker_machines](https://github.com/seuros/breaker_machines) Ruby gem.

## The core

[`Breaker`] admits calls, records their outcomes in a fixed window of `N`
and moves between [`State::Closed`], [`State::Open`] and
[`State::HalfOpen`]. The caller supplies every instant (a [`Duration`] since
an epoch it picks) and every random draw. A [`Refusal`] changes nothing.

```rust
use breaker_machines::{
    Admitted, Breaker, Completed, Outcome, Policy, Recovery, Refusal, Settled, State, Threshold,
};
use core::num::NonZeroU32;
use core::time::Duration;

let secs = Duration::from_secs;
let one = NonZeroU32::MIN;
// Two failures in a minute open it; it probes after 30 s; one success closes it.
let policy = Policy::new(
    Threshold::new(NonZeroU32::new(2), None, 0).ok_or("threshold")?,
    secs(60),
    Recovery::new(secs(30), 0.0, one, one).ok_or("recovery")?,
    None,
)
.ok_or("policy")?;
let mut breaker = Breaker::<64>::new(policy);

for at in [1, 2] {
    let mut ticket = breaker.admit(secs(at))?.into_ticket();
    breaker.complete(&mut ticket, Outcome::Failure, secs(at), 0)?;
}
assert_eq!(breaker.state(), State::Open);
assert_eq!(breaker.admit(secs(10)), Err(Refusal::Open));

let Admitted::HalfOpened(mut probe) = breaker.admit(secs(32))? else {
    return Err("the cooldown elapsed".into());
};
assert_eq!(
    breaker.complete(&mut probe, Outcome::Success, secs(33), 0),
    Ok(Completed::Settled(Settled::Closed)),
);
// A repeat of the same settlement is honoured and changes nothing.
assert_eq!(
    breaker.complete(&mut probe, Outcome::Success, secs(34), 0),
    Ok(Completed::Duplicate(Settled::Closed)),
);
# Ok::<(), Box<dyn core::error::Error>>(())
```

Tickets carry ids issued through `periscope-machines`: build breakers that
may see each other's tickets `with_scope` so a foreign ticket is refused as
[`Refusal::Unknown`]. The cooldown is a `chrono-machines` `Constant`,
jittered by the draw passed when the circuit opens.

Identities never wrap. Every transition takes the next `u64` epoch, which
fences the tickets admitted before it; once the last is taken, a call that
would transition is `Refusal::Exhausted` with nothing changed, while calls
that would not are still honoured. `MemoryStorage` treats its circuit
generations and probe tokens the same way, answering a `StorageError` of
kind `StorageErrorKind::Exhausted` (a failing backend is
`StorageErrorKind::Backend`). `DistributedCircuitBreaker` answers the
exhausted kind as `Refusal::Exhausted`, and a backend failure as
`CircuitError::Storage`.

## The runtime (`std`, `async`)

```rust
# #[cfg(not(feature = "std"))] fn main() {}
# #[cfg(feature = "std")] fn main() -> Result<(), Box<dyn core::error::Error>> {
use breaker_machines::{CircuitBreaker, CircuitError, Policy, Recovery, Refusal, Threshold};
use core::num::NonZeroU32;
use core::time::Duration;

# let one = NonZeroU32::MIN;
# let policy = Policy::new(
#     Threshold::new(Some(one), None, 0).ok_or("threshold")?,
#     Duration::from_secs(60),
#     Recovery::new(Duration::from_secs(30), 0.0, one, one).ok_or("recovery")?,
#     None,
# )
# .ok_or("policy")?;
let mut circuit = CircuitBreaker::builder("payments", policy)
    .on_open(|name| eprintln!("{name} opened"))
    .build();
let charge = || Err::<&str, _>("card network down");
assert_eq!(circuit.call(charge), Err(CircuitError::Execution("card network down")));
assert!(matches!(
    circuit.call(charge),
    Err(CircuitError::Refused { refusal: Refusal::Open, .. }),
));
# Ok(())
# }
```

`async` adds `AsyncCircuitBreaker` (decisions under a short lock, futures
awaited outside it; a cancelled call gives its slots back) and
`DistributedCircuitBreaker`, whose state lives in an `AsyncStorageBackend`
shared by every gateway, with fenced half-open probe leases. Its per-node
`max_concurrent` slot is checked and taken in one atomic step, so the
in-flight count never passes the limit or wraps.

[`Breaker`]: https://docs.rs/breaker-machines/latest/breaker_machines/struct.Breaker.html
[`State::Closed`]: https://docs.rs/breaker-machines/latest/breaker_machines/enum.State.html
[`State::Open`]: https://docs.rs/breaker-machines/latest/breaker_machines/enum.State.html
[`State::HalfOpen`]: https://docs.rs/breaker-machines/latest/breaker_machines/enum.State.html
[`Refusal`]: https://docs.rs/breaker-machines/latest/breaker_machines/enum.Refusal.html
[`Refusal::Unknown`]: https://docs.rs/breaker-machines/latest/breaker_machines/enum.Refusal.html
[`Duration`]: https://doc.rust-lang.org/core/time/struct.Duration.html
