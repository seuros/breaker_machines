# Contributing to BreakerMachines

Welcome to the Resistance! We appreciate your interest in making BreakerMachines better.

## 🎯 Project Philosophy & Scope

**BreakerMachines is intentionally feature-complete.** This gem implements the circuit breaker pattern—nothing more, nothing less. I maintain a sharp focus on doing one thing exceptionally well.

### What I Accept

- **Bug fixes**: Legitimate defects in the existing implementation
- **Performance optimizations**: Measurable improvements to speed or memory usage
- **Language evolution**: Updates for new Ruby syntax and idioms

### What I Don't Accept

- **Legacy support**: The past is a foreign country. Upgrade your dependencies.
- **Feature creep**: If it's not directly related to circuit breaking, it doesn't belong here
- **Domain-specific adapters**: Your business logic is your responsibility
- **Kitchen-sink syndrome**: This will never become a Swiss Army knife of resilience patterns

### On Examples & Metaphors

I use spaceships in the documentation because circuit breakers are about preventing cascade failures—a concept immediately graspable when your warp drive explodes and you need to prevent it from taking out life support. The pattern remains identical whether you're protecting payment gateways, medical device APIs, or autonomous agent orchestration.

I've provided the architectural pattern. Implementation details for your specific domain are left as an exercise for the reader.

## Getting Started

```bash
git clone https://github.com/yourusername/breaker_machines.git
cd breaker_machines
bundle install
bundle exec rake test
```

## Understanding the Architecture

### State Machines Integration

BreakerMachines uses the `state_machines` gem as its foundation for managing circuit states. Here's how it works:

#### The State Machine

In `lib/breaker_machines/circuit.rb`, we define a state machine with three states:

```ruby
state_machine :status, initial: :closed do
  # States:
  # - :closed (initial) - Circuit is functioning normally
  # - :open - Circuit has failed and is rejecting calls
  # - :half_open - Circuit is testing if the service has recovered

  # Events that trigger state transitions:
  event :trip do
    transition closed: :open
    transition half_open: :open
  end

  event :attempt_recovery do
    transition open: :half_open
  end

  event :reset do
    transition [:open, :half_open] => :closed
  end
end
```

#### Why state_machines?

1. **Battle-tested**: The gem has been around since 2008 and is extremely stable
2. **Clean DSL**: Provides a declarative way to define states and transitions
3. **Callbacks**: Built-in support for before/after transition callbacks
4. **Thread-safe**: State transitions are atomic
5. **Introspection**: Automatic generation of predicate methods (`open?`, `closed?`, etc.)

#### How We Use It

The state machine handles the core circuit breaker logic:
- When failures exceed threshold: `trip` event moves to `:open`
- After reset timeout: `attempt_recovery` moves to `:half_open`
- Successful call in half-open: `reset` moves to `:closed`
- Failed call in half-open: `trip` moves back to `:open`

### Storage Backends

Storage backends implement the `Storage::Base` interface:

```ruby
module Storage
  class Base
    def record_success(circuit_name, duration = nil); end
    def record_failure(circuit_name, duration = nil); end
    def success_count(circuit_name, window = nil); end
    def failure_count(circuit_name, window = nil); end
    def get_status(circuit_name); end
    def set_status(circuit_name, status, opened_at = nil); end
  end
end
```

Available backends:
- `Memory`: Simple in-memory storage with mutex synchronization
- `BucketMemory`: Efficient sliding window using circular buffers (default)
- `Null`: No-op implementation for minimal overhead

### Thread Safety

We use `concurrent-ruby` extensively:
- `Concurrent::ReentrantReadWriteLock` for circuit state protection
- `Concurrent::AtomicReference` for atomic values
- `Concurrent::Map` for thread-safe collections
- `WeakRef` for memory-efficient instance tracking

## Development Guidelines

### Running Tests

```bash
# Run all tests
bundle exec rake test

# Run specific test file
bundle exec ruby -Itest test/circuit_test.rb

# Run with specific seed (for debugging intermittent failures)
bundle exec rake test TESTOPTS="--seed=12345"
```

### Code Style

- Follow standard Ruby conventions
- Keep methods small and focused
- Add comments for complex logic
- Maintain 100% test coverage for new features

### Adding New Features

1. Discuss the feature in an issue first
2. Write tests before implementation
3. Ensure backward compatibility
4. Update documentation and examples
5. Add entry to CHANGELOG.md

### Safety First

Remember: BreakerMachines prioritizes safety over features. We do NOT implement:
- Forceful timeouts (no `Timeout.timeout` or `Thread#kill`)
- Any operations that could corrupt state
- Features that compromise thread safety

## Submitting Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request with a clear description

### PR Checklist

- [ ] Tests pass (`bundle exec rake test`)
- [ ] Documentation updated
- [ ] CHANGELOG.md entry added
- [ ] No forceful timeouts introduced
- [ ] Thread-safe implementation
- [ ] Backward compatible (or major version bump justified)

## Questions?

Feel free to open an issue for any questions. The Resistance is here to help!

## License

By contributing, you agree that your contributions will be licensed under the MIT License.