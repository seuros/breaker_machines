# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rb_sys/extensiontask'

GEMSPEC = Gem::Specification.load('breaker_machines.gemspec')

SUPPORTED_NATIVE_PLATFORMS = %w[
  arm64-darwin
  x86_64-darwin
  aarch64-linux
  x86_64-linux
  x86_64-linux-musl
].freeze

native_ext = RbSys::ExtensionTask.new('breaker_machines_native', GEMSPEC) do |ext|
  ext.lib_dir = 'lib/breaker_machines_native'
  ext.tmp_dir = 'tmp/rb_sys'
  ext.cross_platform = SUPPORTED_NATIVE_PLATFORMS if ENV.key?('RUBY_TARGET')
end

# A single-version cross build stages its binary at the host binary's path,
# which the gem package depends on, so packaging would also compile for the
# host and fail where the host linker can't target the platform.
if ENV.key?('RUBY_TARGET')
  host_binary = "#{native_ext.lib_dir}/#{native_ext.name}.#{RbConfig::CONFIG['DLEXT']}"
  Rake::Task[host_binary].clear_prerequisites if Rake::Task.task_defined?(host_binary)
end

desc 'Compile and run the Ruby tests, each in its own forked cell'
task test: :compile do
  sh 'padded_cell'
end

desc 'Test the standalone Rust core'
task :cargo do
  sh 'cargo', 'test', '-p', 'breaker-machines'
end

desc 'Validate Ruby signatures against the stdlib sigs sig/manifest.yaml declares'
task :rbs do
  require 'yaml'
  libraries = YAML.load_file('sig/manifest.yaml').fetch('dependencies').map { it.fetch('name') }
  sh 'rbs', *libraries.flat_map { ['-r', it] }, '-I', 'sig', 'validate'
end

task default: %i[test cargo rbs]

Dir[File.join(__dir__, 'tasks/*.rake')].sort.each { |f| load f }
