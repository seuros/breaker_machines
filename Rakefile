# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'

Minitest::TestTask.create

GEMSPEC = Gem::Specification.load('breaker_machines.gemspec')

if RUBY_ENGINE != 'jruby'
  begin
    require 'rb_sys/extensiontask'
  rescue LoadError
    warn 'rb_sys not available; native build tasks disabled'
  end
end

SUPPORTED_NATIVE_PLATFORMS = %w[
  arm64-darwin
  x86_64-darwin
  aarch64-linux
  x86_64-linux
  x86_64-linux-musl
  aarch64-linux-musl
  arm-linux
].freeze

if defined?(RbSys::ExtensionTask)
  RbSys::ExtensionTask.new('breaker_machines_native', GEMSPEC) do |ext|
    ext.lib_dir = 'lib/breaker_machines_native'
    ext.tmp_dir = 'tmp/rb_sys'
    ext.cross_platform = SUPPORTED_NATIVE_PLATFORMS if ENV.key?('RUBY_TARGET')
  end

  namespace :native do
    desc 'Compile the native extension in release mode for the current platform'
    task build: ['rb_sys:env:release', 'compile']

    desc 'Build native gems for all supported platforms'
    task :all do
      SUPPORTED_NATIVE_PLATFORMS.each do |platform|
        sh({ 'RUBY_TARGET' => platform }, 'bundle', 'exec', 'rake', 'native:build')
      end
    end
  end
end

task default: :test
