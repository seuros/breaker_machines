# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.4](https://github.com/seuros/breaker_machines/compare/breaker-machines-v0.7.3...breaker-machines-v0.7.4) (2026-01-23)


### Bug Fixes

* update state-machines ([#54](https://github.com/seuros/breaker_machines/issues/54)) ([108af96](https://github.com/seuros/breaker_machines/commit/108af96df17df7773bc35dedd512a3a3cbb0251f))

## [0.7.3](https://github.com/seuros/breaker_machines/compare/breaker-machines-v0.7.2...breaker-machines-v0.7.3) (2026-01-16)


### Bug Fixes

* update crate dependencies ([#52](https://github.com/seuros/breaker_machines/issues/52)) ([2c5e382](https://github.com/seuros/breaker_machines/commit/2c5e382edc08d7d283334c57af3a4b97b1315dd7))

## [0.7.2](https://github.com/seuros/breaker_machines/compare/breaker-machines-v0.7.1...breaker-machines-v0.7.2) (2025-12-11)


### Bug Fixes

* remove unused variable in jitter variance test ([cfbd8e0](https://github.com/seuros/breaker_machines/commit/cfbd8e00118db8b93464ef8cc65ba894e809ce44))

## [0.7.1](https://github.com/seuros/breaker_machines/compare/breaker-machines-v0.7.0...breaker-machines-v0.7.1) (2025-11-25)


### Bug Fixes

* callback panic safety and expanded test coverage ([#46](https://github.com/seuros/breaker_machines/issues/46)) ([5414bc6](https://github.com/seuros/breaker_machines/commit/5414bc6d60e102dca4ba78bf13134f48e2c22de3))
* callback panic safety and expanded test coverage ([#48](https://github.com/seuros/breaker_machines/issues/48)) ([6dbeb3d](https://github.com/seuros/breaker_machines/commit/6dbeb3d3653b2d1208f119fcebe7f3a9015193cc))

## [0.7.0](https://github.com/seuros/breaker_machines/compare/breaker-machines-v0.6.0...breaker-machines-v0.7.0) (2025-11-24)


### Features

* circuit breaker bookkeeping and HalfOpen counter reset ([#44](https://github.com/seuros/breaker_machines/issues/44)) ([ef2bac7](https://github.com/seuros/breaker_machines/commit/ef2bac77d6c0024265498d2173816e906fa4fb39))

## [0.6.0](https://github.com/seuros/breaker_machines/compare/breaker-machines-v0.3.0...breaker-machines-v0.6.0) (2025-11-05)


### Features

* add native storage backend with Rust v0.3.0 and Rails 8+ support ([#21](https://github.com/seuros/breaker_machines/issues/21)) ([cf45b0a](https://github.com/seuros/breaker_machines/commit/cf45b0aa8444a86b5ce20e1627013c532c56169e))


### Bug Fixes

* configure release-please for monorepo with Ruby and Rust packages ([656127c](https://github.com/seuros/breaker_machines/commit/656127c4588010f33822ca5114ba3e9ebbeb6df5))
* version ([c69d413](https://github.com/seuros/breaker_machines/commit/c69d41371ea9b72c63b0cce11825f6059a45b8f3))


### Code Refactoring

* fix clippy warnings in Rust crate ([7dd1230](https://github.com/seuros/breaker_machines/commit/7dd1230bdfc1beff377c4b9c332727beabb996ab))

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
