# Changelog

## [0.7.0](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.6.2...breaker_machines/v0.7.0) (2025-11-11)


### Bug Fixes

* cross gem perms ([#28](https://github.com/seuros/breaker_machines/issues/28)) ([e35b9b7](https://github.com/seuros/breaker_machines/commit/e35b9b7fc0383aaf601bce24a492a63de5ff07ec))
* Fix/release cross gem perms ([#30](https://github.com/seuros/breaker_machines/issues/30)) ([717a152](https://github.com/seuros/breaker_machines/commit/717a152b055d2df1c0d2d3b4697f553c09ea881d))

## [0.6.2](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.6.1...breaker_machines/v0.6.2) (2025-11-05)


### Bug Fixes

* install rb_sys to user gem home in release ([#26](https://github.com/seuros/breaker_machines/issues/26)) ([909ae50](https://github.com/seuros/breaker_machines/commit/909ae505a68fe3ea96648f626eefc33ae3470eb8))

## [0.6.1](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.6.0...breaker_machines/v0.6.1) (2025-11-05)


### Bug Fixes

* bundle rb_sys for source installs ([#24](https://github.com/seuros/breaker_machines/issues/24)) ([adeed7e](https://github.com/seuros/breaker_machines/commit/adeed7e7eac2f974d95ffb7ca93c02a4183d36f0))

## [0.6.0](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.5.0...breaker_machines/v0.6.0) (2025-11-05)


### Features

* add native storage backend with Rust v0.3.0 and Rails 8+ support ([#21](https://github.com/seuros/breaker_machines/issues/21)) ([cf45b0a](https://github.com/seuros/breaker_machines/commit/cf45b0aa8444a86b5ce20e1627013c532c56169e))


### Bug Fixes

* configure release-please for monorepo with Ruby and Rust packages ([656127c](https://github.com/seuros/breaker_machines/commit/656127c4588010f33822ca5114ba3e9ebbeb6df5))


### Code Refactoring

* fix clippy warnings in Rust crate ([7dd1230](https://github.com/seuros/breaker_machines/commit/7dd1230bdfc1beff377c4b9c332727beabb996ab))

## [0.5.0](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.4.2...breaker_machines/v0.5.0) (2025-09-10)


### Bug Fixes

* version ([c69d413](https://github.com/seuros/breaker_machines/commit/c69d41371ea9b72c63b0cce11825f6059a45b8f3))

## [0.4.2](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.4.1...breaker_machines/v0.4.2) (2025-09-10)


### Features

* modernize async API to leverage 2.31.0 features ([#19](https://github.com/seuros/breaker_machines/issues/19)) ([8360716](https://github.com/seuros/breaker_machines/commit/836071690cee92febdc7d66d9839dbfb68fe486f))


### Bug Fixes

* implement hard_reset event for proper test isolation ([#16](https://github.com/seuros/breaker_machines/issues/16)) ([0e0c31f](https://github.com/seuros/breaker_machines/commit/0e0c31f0c5e289be77c453b41ea56a8b96449610))
* resolve race condition in parallel fallback execution ([#18](https://github.com/seuros/breaker_machines/issues/18)) ([07eed69](https://github.com/seuros/breaker_machines/commit/07eed69092dc4747251e10d6501a054570198e5f))

## [0.4.1](https://github.com/seuros/breaker_machines/compare/breaker_machines-v0.4.0...breaker_machines/v0.4.1) (2025-09-10)


### Features

* add state_machines v0.100.0 features and enhancements ([#10](https://github.com/seuros/breaker_machines/issues/10)) ([dc32336](https://github.com/seuros/breaker_machines/commit/dc323365c05e8d1faf0421f3dbc0d62487378a03))
* allow rails 7.2 to use this gem ([027a8b8](https://github.com/seuros/breaker_machines/commit/027a8b8baeb296c5436b9f4f7db168012ff1fb9e))
* cascading circuits aka "Shield Harmonics" ([#7](https://github.com/seuros/breaker_machines/issues/7)) ([310bfe6](https://github.com/seuros/breaker_machines/commit/310bfe665c099a510cd358919c095b5c8f89e7fc))
* created adapter for Rails cache stores ([#1](https://github.com/seuros/breaker_machines/issues/1)) ([2f423e9](https://github.com/seuros/breaker_machines/commit/2f423e9a6f2dc3c82ddeb5eab4bd290ae464c664))
* dynamic circuits ([b63597b](https://github.com/seuros/breaker_machines/commit/b63597b6136b35e05bf7ad4d87fadf628da99461))
* extract instrumentation for fallback chain ([5880304](https://github.com/seuros/breaker_machines/commit/588030463b36cfb483dc7c20d5ded65a5a75a8ff))
* fallback_chain feature ([#6](https://github.com/seuros/breaker_machines/issues/6)) ([fc0df2e](https://github.com/seuros/breaker_machines/commit/fc0df2e69407f5fa900208fcab1409cc836e4605))


### Bug Fixes

* circuit breaker deadlock in bulkheading feature ([#2](https://github.com/seuros/breaker_machines/issues/2)) ([f72349c](https://github.com/seuros/breaker_machines/commit/f72349c1e6792a5cb71e1bdfbf34fd00c9efd86c))
* correct fiber_safe syntax ([1024400](https://github.com/seuros/breaker_machines/commit/10244005c40ac1b248dc5eb746056b9de27f8a1c))
* extract hedged requests ([94dfcc1](https://github.com/seuros/breaker_machines/commit/94dfcc1ebd967a4bc04e3dff12c89eecbc9f13bf))
* extract hedged requests ([afd9b4b](https://github.com/seuros/breaker_machines/commit/afd9b4b3b5792798fffdb2b1afb17b8ba337013d))
