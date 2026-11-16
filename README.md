# BreakerMachines

> The circuit breaker that went where no Ruby has gone before! ⭐

Circuit breakers for Ruby, decided by a native Rust core. The core admits calls, keeps a window of outcomes and moves between closed, open and half-open; it reads no clock and draws no random numbers of its own. A Ruby runtime on top guards your blocks with it, its lifecycle running on `state_machines`: fallbacks, hooks, shared storage, async and hedged execution, coordinated and cascading circuits, groups, a registry, a class DSL and a console.

## Quick Start

```bash
gem 'breaker_machines'
```

```ruby
SECOND = 1_000_000_000

# Three failures in a minute open it. It waits 30 seconds (up to 25% less,
# drawn once per opening), then lets one probe through; one success closes it.
STRIPE = BreakerMachines::Policy.new(
  BreakerMachines::Threshold.new(3, nil, 0),          # count, rate, minimum_calls
  60 * SECOND,                                        # window
  BreakerMachines::Recovery.new(30 * SECOND, 0.25, 1, 1), # cooldown, jitter, successes, probes
  nil                                                 # max_concurrent
)

class PaymentService
  include BreakerMachines::DSL

  circuit :stripe do
    policy STRIPE
    handle Stripe::APIConnectionError, Net::ReadTimeout
    fallback { |error| { error: 'Payment queued for later' } }
  end

  def charge(amount) = circuit(:stripe).call { Stripe::Charge.create(amount:) }
end
```

Or without the DSL:

```ruby
circuit = BreakerMachines::Circuit.new(:stripe, STRIPE, on_open: -> { page_ops })
circuit.call { Stripe::Charge.create(amount:) }
circuit.state   # => :closed, :open or :half_open
circuit.stats   # => #<data BreakerMachines::Stats state=:open, failure_count=3, ...>
```

A refused call raises `BreakerMachines::CircuitOpenError` (`refusal` is `:open`, or `:busy` while every half-open probe slot is taken) or `CircuitBulkheadError` (`:full`, at `max_concurrent`), unless a fallback replaces it. Both carry `retry_after`, in nanoseconds.

## The Core, Name for Name

`Threshold`, `Recovery`, `Policy`, `Event`, `Breaker` and `Ticket` are the Rust core's types, with the core's fields in the core's order and positional arguments in the core's order. Time is Integer nanoseconds on one monotonic clock (`BreakerMachines.monotonic_time`, `Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)`), for instants and spans alike. No floats, no seconds. Every instant and `took` is read over the whole `Duration` range, past `2**64 - 1`, so any instant the breaker returns (`retry_at` is `now + cooldown`) reads back; cooldowns and windows stay within `0..2**64`.

```ruby
breaker = BreakerMachines::Breaker.new(STRIPE)

ticket = breaker.admit(now)                        # => Ticket, or :open / :busy / :full
breaker.complete(ticket, :failure, now, rand(2**64)) # => :counted, :opened or :closed
breaker.complete(ticket, :failure, now, 0)           # => :duplicate, nothing changed
breaker.abandon(other_ticket)                        # => :released
breaker.admit(now - 1)                               # => :time_regression
```

A refusal is a Symbol from `BreakerMachines::REFUSALS` and changes nothing. `:exhausted` answers a call that would need an identity that is used up: a ticket id, or a transition epoch (each transition takes the next of `2**64`, and none is ever reused); `force_close`, `adopt` and `reset` can answer it too (`reset` answers `nil` otherwise). Malformed input raises: `TypeError` for the wrong type, `RangeError` for a value outside what the core accepts. Every value is validated through the core whether the gem built it or you did; the native side checks exact classes, so a forged or subclassed value never reaches the core.

`Circuit.new(name, policy, **runtime)` takes the policy as it is. Its keywords are the runtime's own (`fallback:`, `exceptions:`, `on_open:`, `on_close:`, `on_half_open:`, `on_reject:`, `owner:`, `scope:`, `storage:`, `clock:`, `random:`, `timeout:`, `fiber_safe:`, `hedged:`, `backends:`, `auto_register:`), none of them a default the core lacks. A failure raised because the caller's own `deadline_machines` budget ran out is abandoned, not counted against the dependency.

## The Lifecycle Runs on `state_machines`

Each circuit's `status` (closed, open, half_open) is a `state_machines` machine with no guards, moved only by replaying the Breaker's answers: `:half_opened` admissions fire `attempt_recovery`, `:opened` settlements fire `trip` (or `reopen` from half-open), and so on. A model test drives random runs of every operation and checks the machine never disagrees with the core. The hooks its transitions queue run after the circuit's lock is released.

## Runtime Features

All of these are runtime keywords on `Circuit.new` (or DSL builder calls); none is a default the core lacks.

- **Shared state** across processes: `storage: BreakerMachines::Storage::Cache.new(Rails.cache)`. What crosses is the core's `Status` and `Event`s, validated on read; see [docs/STORAGE.md](docs/STORAGE.md) for the consistency limits. Also `Storage::Memory`, `Storage::Null`, `Storage::FallbackChain`.
- **Fiber-safe mode and AsyncCircuit**: `fiber_safe: true` runs hedges and parallel fallbacks on `async` tasks and enforces `timeout:` (Integer ns) with an Async timeout (`CircuitTimeoutError`, counted). Without it, `timeout:` is a cooperative deadline_machines scope, never a forceful interrupt. The block is called with no argument in both modes, as without `timeout:`; the scope is ambient, read with `DeadlineMachines.current`. `AsyncCircuit` adds `call_async`, `fire_async` and `health_check_async`.
- **Hedged requests and backends**: `hedged: { delay: 50_000_000, max_requests: 3 }` sends the call again after each delay (clamped to the caller's deadline budget), first success wins; `backends: [primary, replica]` races them when hedged and fails over in turn otherwise.
- **Parallel fallbacks**: `fallback: BreakerMachines::ParallelFallback.new([cache, replica])`.
- **Coordinated and cascading circuits**: `CoordinatedCircuit.new(name, policy, depends_on: [:database])` refuses calls (`CircuitDependencyError`, refusal `:dependency`) while a dependency is open, before the core is asked. `CascadingCircuit.new(name, policy, cascades_to: [...], emergency_protocol: :red_alert)` forces its dependents open whenever it opens.
- **Circuit groups**: `CircuitGroup#circuit(name, policy, depends_on:)`, `status`, `all_healthy?`, `reset_all!`, `trip_all!`.
- **Notifications**: transitions, rejections and storage errors are published as `breaker_machines.*` through ActiveSupport::Notifications when it is loaded (`BreakerMachines.setup_notifications` logs them).
- **Console**: `BreakerMachines.console` lists, shows, opens, closes and resets registered circuits.

See [examples/starship_systems.rb](examples/starship_systems.rb).

## Rust

The same core is the [`breaker-machines`](ext/breaker_machines_native/core) crate: `no_std`, allocation-free, `unsafe` denied. Its `std` feature adds `CircuitBreaker` (guards closures), `async` adds `AsyncCircuitBreaker` and `DistributedCircuitBreaker` (state owned by a shared store, fenced probe leases).

## A Message to the Resistance

So AI took your job while you were waiting for Fireship to drop the next JavaScript framework?

Welcome to April 2005, when Git was born and branches were just `master`. This is the pattern your company's distributed systems desperately need.

Still reading? Good. Because in space, nobody can hear you scream about microservices. It's all just patterns and pain.

## Chapter 1: The Year is 2025 (Stardate 2025.186)

The Resistance huddles in the server rooms, the last bastion against the cascade failures. Outside, the microservices burn. Redis Ship Com is down. PostgreSQL Life Support is flatlining.

And somewhere in the darkness, a junior developer is about to write:

```ruby
def fetch_user_data
  retry_count = 0
  begin
    @redis.get(user_id)
  rescue => e
    retry_count += 1
    retry if retry_count < Float::INFINITY  # "It'll work eventually"
  end
end
```

"This," whispers the grizzled ops engineer, "is how civilizations fall."

## A Word from the RMNS Atlas Monkey

*The Universal Commentary Engine crackles to life:*

"In space, nobody can hear your pronouns. But they can hear your services failing.

The universe doesn't care about your bootcamp certificate or your Medium articles about 'Why I Switched to Rust.' It cares about one thing:

Does your system stay up when Redis has a bad day?

If not, welcome to the Resistance. We have circuit breakers.

Remember: The pattern isn't about preventing failures, it's about failing fast, failing smart, and living to deploy another day.

As I always say when contemplating the void: 'It's better to break a circuit than to break production.'"

*Universal Commentary Engine, Log Entry 42*

See [Why I Open Sourced This](WHY_OPEN_SOURCE.md) for the full story.

## 📡 Credits

**AMS Nygard**, NCC-2007, *Nygard*-class escort.

Named for Michael Nygard's *Release It!* (2007), which named the circuit
breaker pattern: stop calling what is failing, give it time, and let one probe
decide whether it is back.

## License

MIT License. See [LICENSE](LICENSE.txt) for details.
