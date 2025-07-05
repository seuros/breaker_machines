# frozen_string_literal: true

require_relative 'lib/breaker_machines/version'

Gem::Specification.new do |spec|
  spec.name = 'breaker_machines'
  spec.version = BreakerMachines::VERSION
  spec.authors = ['Abdelkader Boudih']
  spec.email = ['terminale@gmail.com']

  spec.summary = 'Circuit breaker implementation for Ruby with a clean DSL and state_machines under the hood'
  spec.description = <<~DESC
    BreakerMachines is a production-ready circuit breaker implementation for Ruby that prevents
    cascade failures in distributed systems. Built on the battle-tested state_machines gem, it
    provides a clean DSL, thread-safe operations, multiple storage backends, and comprehensive
    introspection tools. Unlike other solutions, BreakerMachines prioritizes safety by avoiding
    dangerous forceful timeouts while supporting fallback chains, jitter, and event callbacks.
  DESC
  spec.homepage = 'https://github.com/seuros/breaker_machines'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  # Allow push to RubyGems.org
  spec.metadata['allowed_push_host'] = 'https://rubygems.org'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/seuros/breaker_machines'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/seuros/breaker_machines/issues'
  spec.metadata['documentation_uri'] = 'https://github.com/seuros/breaker_machines#readme'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem
  spec.files = Dir['lib/**/*'] + Dir['sig/**/*'] + %w[LICENSE.txt README.md]
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Core dependencies
  spec.add_dependency 'activesupport', '>= 8.0'
  spec.add_dependency 'concurrent-ruby', '~> 1.3'
  spec.add_dependency 'state_machines', '>= 0.31.0'
  spec.add_dependency 'zeitwerk', '~> 2.7'

  # Development dependencies
  spec.add_development_dependency 'minitest', '~> 5.16'
  spec.add_development_dependency 'rake', '~> 13.0'
end
