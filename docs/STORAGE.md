# Sharing circuit state

A circuit with `storage:` shares its lifecycle with every circuit of the same name that uses the same backend: one process opening the circuit opens it everywhere, and one recovering closes it everywhere.

```ruby
storage = BreakerMachines::Storage::Cache.new(Rails.cache, expires_in: 300)
circuit = BreakerMachines::Circuit.new(:stripe, STRIPE, storage:)
```

Backends: `Storage::Memory` (one process), `Storage::Cache` (any store answering `read`, `write(key, value, expires_in:)` and `delete`, such as `Rails.cache`), `Storage::Null` (shares nothing) and `Storage::FallbackChain.new([redis_cache, memory])` (first backend that does not raise; a failing one is skipped for `cooldown` nanoseconds).

## What crosses the boundary

Only the core's own values: a `Storage::Record` holding the Breaker's `Status` (`state`, `opened_at`, `retry_at`) and a generation, and the `Event`s circuits recorded. A serializing backend stores them as plain arrays and rebuilds them through `Status.new` and `Event.new` on read, so a stored value is validated like any other. An invalid record raises `StorageError` inside the backend; the circuit reports it (`breaker_machines.storage_error`) and adopts nothing.

Before each call a circuit reads the record; when its generation is newer than the last one it saw, the Breaker adopts the Status (`Breaker#adopt`) and the lifecycle machine replays the answer, firing the usual hooks. After each transition the circuit writes its Status under the next generation.

## Consistency limits

- **The lifecycle is shared; the window is not.** Each process judges its own failures against the threshold. Shared events feed `Circuit#events` for observability only.
- **Last write wins.** Two processes transitioning at once may write the same generation; the later write wins and the other converges on its next call.
- **Probe and concurrency limits are per process.** Several processes may each send a half-open probe.
- **One clock.** Status instants must be comparable across processes, so a circuit with a storage reads `BreakerMachines.wall_time` (CLOCK_REALTIME nanoseconds) unless given another `clock:`. A wall clock that steps back reads as standing still.
- **Expiry.** `Storage::Cache` records expire after `expires_in` seconds (the cache store's unit); an expired record means "no news", never "closed".

For a store-owned state machine with fenced half-open probe leases, use the Rust crate's `DistributedCircuitBreaker`.
