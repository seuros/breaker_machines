# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-01-XX

### Added
- **Fallback Support**: Provide fallback functions that execute when circuit is open
  - `CallOptions` API for flexible call configuration
  - `FallbackContext` provides circuit name, opened_at, and state to fallback closures
  - Backward compatible - plain closures still work as before
- **Rate-based Thresholds**: Trip circuit based on failure percentage
  - `failure_rate_threshold` - percentage of failures (0.0-1.0) that opens circuit
  - `minimum_calls` - minimum number of calls before rate is evaluated
  - Can be used alone or combined with absolute `failure_threshold`
- New builder methods:
  - `.failure_rate(f64)` - set failure rate threshold
  - `.minimum_calls(usize)` - set minimum calls for rate evaluation
  - `.disable_failure_threshold()` - use only rate-based thresholds

### Changed
- `Config` struct is no longer `Copy` (contains optional closures)
- `failure_threshold` is now `Option<usize>` (can be disabled)
- Updated description to highlight new features

### Tests
- Added comprehensive tests for fallback behavior
- Added tests for rate-based threshold logic
- Added tests for minimum_calls guards
- All 28 tests passing

## [0.1.0] - 2025-01-20

### Added
- Initial release
- Core circuit breaker with state machine (Closed/Open/HalfOpen)
- Thread-safe `MemoryStorage` with sliding window
- `NullStorage` for testing
- Builder API with fluent configuration
- Callbacks for state transitions (`on_open`, `on_close`, `on_half_open`)
- Jitter support using chrono-machines
- 23 comprehensive tests
- Documentation and examples
