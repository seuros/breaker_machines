# Changelog

## [0.10.2](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.10.1...breaker_machines/v0.10.2) (2025-12-11)


### Bug Fixes

* remove unused variable in jitter variance test ([cfbd8e0](https://github.com/seuros/breaker_machines/commit/cfbd8e00118db8b93464ef8cc65ba894e809ce44))

## [0.10.1](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.10.0...breaker_machines/v0.10.1) (2025-11-25)


### Bug Fixes

* callback panic safety and expanded test coverage ([#46](https://github.com/seuros/breaker_machines/issues/46)) ([5414bc6](https://github.com/seuros/breaker_machines/commit/5414bc6d60e102dca4ba78bf13134f48e2c22de3))
* callback panic safety and expanded test coverage ([#48](https://github.com/seuros/breaker_machines/issues/48)) ([6dbeb3d](https://github.com/seuros/breaker_machines/commit/6dbeb3d3653b2d1208f119fcebe7f3a9015193cc))

## [0.10.0](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.9.4...breaker_machines/v0.10.0) (2025-11-24)


### Features

* circuit breaker bookkeeping and HalfOpen counter reset ([#44](https://github.com/seuros/breaker_machines/issues/44)) ([ef2bac7](https://github.com/seuros/breaker_machines/commit/ef2bac77d6c0024265498d2173816e906fa4fb39))

## [0.9.4](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.9.3...breaker_machines/v0.9.4) (2025-11-24)


### Bug Fixes

* update crate ([6b5fac4](https://github.com/seuros/breaker_machines/commit/6b5fac4504454039182765675832288a4fa3eab4))

## [0.9.3](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.9.2...breaker_machines/v0.9.3) (2025-11-23)


### Bug Fixes

* Remove empty env block in manual-native-build.yml ([2487c95](https://github.com/seuros/breaker_machines/commit/2487c953e6e799c538842c9cc1ed8573e349948a))
* Set BREAKER_MACHINES_NATIVE env var before require in CI test ([62a2eca](https://github.com/seuros/breaker_machines/commit/62a2eca430bc0e963c3e87a581556074b48cd695))

## [0.9.2](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.9.1...breaker_machines/v0.9.2) (2025-11-23)


### Bug Fixes

* Use ubuntu-24.04-arm (not arm64) ([1ea562c](https://github.com/seuros/breaker_machines/commit/1ea562cc2c387a3b3f525804af0641f626f6d13f))

## [0.9.1](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.9.0...breaker_machines/v0.9.1) (2025-11-23)


### Bug Fixes

* Use native ARM runner for aarch64-linux builds ([82f4abb](https://github.com/seuros/breaker_machines/commit/82f4abbf095753fb4000197213d8e7ab7a00c326))

## [0.9.0](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.8.4...breaker_machines/v0.9.0) (2025-11-23)


### Features

* Make native extension opt-in at runtime ([5fba9af](https://github.com/seuros/breaker_machines/commit/5fba9afd9c81ab1e00c154b80e62d50bfdd1127e))


### Bug Fixes

* Re-add aarch64-linux with platform-specific cache isolation ([b3e8de3](https://github.com/seuros/breaker_machines/commit/b3e8de37dffe79e56d7ca492c6e58135ca2dc9fc))
* Remove aarch64-linux from build matrix ([aa2d02b](https://github.com/seuros/breaker_machines/commit/aa2d02b22b5ac9b72d8bfd03b11bf51de207e181))

## [0.8.4](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.8.3...breaker_machines/v0.8.4) (2025-11-23)


### Bug Fixes

* Use platform-specific cache-version to prevent cross-contamination ([a5c53d7](https://github.com/seuros/breaker_machines/commit/a5c53d737184209c80c007d8d009203f7b1923bf))

## [0.8.3](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.8.2...breaker_machines/v0.8.3) (2025-11-23)


### Bug Fixes

* Revert opt-in native extension and remove invalid cache-key ([2e6a03f](https://github.com/seuros/breaker_machines/commit/2e6a03f308469dbe4d0c43a3a055573037ce53af))

## [0.8.2](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.8.1...breaker_machines/v0.8.2) (2025-11-23)


### Bug Fixes

* add JRuby and TruffleRuby CI testing ([#11](https://github.com/seuros/breaker_machines/issues/11)) ([8aa1c99](https://github.com/seuros/breaker_machines/commit/8aa1c995a6b75c5fa6d392ce58243b818c2df27e))
* Make native extension opt-in with BREAKER_MACHINES_NATIVE=1 ([#36](https://github.com/seuros/breaker_machines/issues/36)) ([126d631](https://github.com/seuros/breaker_machines/commit/126d63158e83fc7e6ca62cd7392ef62d9a592c5e))

## [0.8.1](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.8.0...breaker_machines/v0.8.1) (2025-11-23)


### Bug Fixes

* Isolate aarch64-linux build with platform-specific cache and target dir ([653ec42](https://github.com/seuros/breaker_machines/commit/653ec427077fe5072e868b2b0c303952217a584f))

## [0.8.0](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.7.1...breaker_machines/v0.8.0) (2025-11-23)


### Features

* Add GEM_PUSH_HOST env var for flexible gem publishing ([16530d6](https://github.com/seuros/breaker_machines/commit/16530d6ec00a44d69e7a84712b07e496ea13d993))
* Add multi-architecture test workflow with musl support ([70017e9](https://github.com/seuros/breaker_machines/commit/70017e900ae068213793512e355e28df85cc47a2))
* Add x86_64-linux-musl platform and GitHub Packages publishing to release workflow ([b661d1a](https://github.com/seuros/breaker_machines/commit/b661d1a9430ebde285214865177e042949bd278f))


### Bug Fixes

* Add --force flag to bypass allowed_push_host restriction ([7edd9b1](https://github.com/seuros/breaker_machines/commit/7edd9b13d1e79d50a0eacda309a9c8bf1024c207))
* Correct publish idempotent logic and gem install syntax ([cab2826](https://github.com/seuros/breaker_machines/commit/cab2826e9dee72fb41fac1e6f8a8edf48a0e3063))
* Handle RubyGems version normalization in test workflow ([b641418](https://github.com/seuros/breaker_machines/commit/b641418222d6822a0051b6c1a9502bdf841f30e8))
* Make publish idempotent and fix smoke test dependencies ([addc7b7](https://github.com/seuros/breaker_machines/commit/addc7b74b26ea73f2dce6247ec3fce67003737ce))
* Make smoke tests non-blocking ([3d22dea](https://github.com/seuros/breaker_machines/commit/3d22dea550b7c4e3c845be401736fe21f2cc4558))
* Reduce to working platforms only - 5 total ([e0ed30b](https://github.com/seuros/breaker_machines/commit/e0ed30bc9098b5e42a2df17806a1671e026ae3c8))
* Remove aarch64-linux from test workflow due to cache corruption ([8315eff](https://github.com/seuros/breaker_machines/commit/8315effc4d5bd5a926f8ca3f623d6601b610df8d))
* Remove unsupported armv7-linux-musl and arm-linux-musl platforms ([a075b6c](https://github.com/seuros/breaker_machines/commit/a075b6ccf6943139549edabf67e5ac12bb1ca0b8))
* Use --allowed-push-host flag to override gemspec restriction ([37e3291](https://github.com/seuros/breaker_machines/commit/37e3291801ed0c2d68ded21eeb234bd2fa841f75))

## [0.7.1](https://github.com/seuros/breaker_machines/compare/breaker_machines/v0.7.0...breaker_machines/v0.7.1) (2025-11-19)


### Bug Fixes

* detect platform binary ([#31](https://github.com/seuros/breaker_machines/issues/31)) ([4f71383](https://github.com/seuros/breaker_machines/commit/4f71383d40e203f8b520b38331abca37941e086c))

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
