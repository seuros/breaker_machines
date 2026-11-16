# frozen_string_literal: true

require_relative 'lib/breaker_machines/version'

Gem::Specification.new do |spec|
  spec.name = 'breaker_machines'
  spec.version = BreakerMachines::VERSION
  spec.authors = ['Abdelkader Boudih']
  spec.email = ['terminale@gmail.com']

  spec.summary = 'Circuit breakers over a native Rust core, with a runtime that guards blocks'
  spec.description = 'Circuit breaker admission, outcome windows and transitions decided by the no_std ' \
                     'breaker-machines core in Integer nanoseconds, with a Ruby runtime for guarding ' \
                     'blocks, fallbacks, hooks, a registry and a class DSL.'
  spec.homepage = 'https://github.com/seuros/breaker_machines'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/seuros/breaker_machines'
  spec.metadata['changelog_uri'] = 'https://github.com/seuros/breaker_machines/blob/master/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['cargo_crate_name'] = 'breaker_machines_native'
  spec.metadata['cargo_manifest_path'] = 'ext/breaker_machines_native/ffi/Cargo.toml'

  spec.files = Dir.glob(%w[
    lib/**/*.rb sig/**/*.rbs sig/manifest.yaml ext/**/*.{rb,rs,toml,md} Cargo.toml
    README.md CHANGELOG.md LICENSE.txt
  ]).select { |path| File.file?(path) }
    .reject { |path| path.end_with?('/tests.rs') || path.include?('/tests/') }
  spec.require_paths = ['lib']
  spec.extensions = ['ext/breaker_machines_native/extconf.rb']

  spec.add_dependency 'deadline_machines', '>= 0.2.0'
  spec.add_dependency 'state_machines', '>= 0.202'
  spec.add_dependency 'rb_sys', '~> 0.9', '>= 0.9.130'
end
