# frozen_string_literal: true

def create_noop_makefile(message)
  warn message
  warn 'BreakerMachines will fall back to pure Ruby backend.'
  File.write('Makefile', <<~MAKE)
    all:
    	@echo '#{message}'
    install:
    	@echo '#{message}'
  MAKE
  exit 0
end

# Native extension is opt-in: require BREAKER_MACHINES_NATIVE=1
unless ENV['BREAKER_MACHINES_NATIVE'] == '1'
  create_noop_makefile('Skipping native extension (set BREAKER_MACHINES_NATIVE=1 to enable)')
end

# Skip native extension compilation on JRuby
if RUBY_ENGINE == 'jruby'
  create_noop_makefile('Skipping native extension on JRuby')
end

# Check if Cargo is available
def cargo_available?
  system('cargo --version > /dev/null 2>&1')
end

unless cargo_available?
  create_noop_makefile('Skipping native extension (Cargo not found)')
end

# Use rb_sys to compile the Rust extension
require 'mkmf'

# Wrap entire compilation process in error handling to ensure gem install never fails
begin
  require 'rb_sys/mkmf'

  require 'pathname'

  create_rust_makefile('breaker_machines_native/breaker_machines_native') do |r|
    ffi_dir = Pathname(__dir__)
    r.ext_dir = begin
      ffi_dir.relative_path_from(Pathname(Dir.pwd)).to_s
    rescue ArgumentError
      ffi_dir.expand_path.to_s
    end
    # Profile configuration
    r.profile = ENV.fetch('RB_SYS_CARGO_PROFILE', :release).to_sym
  end

  makefile_path = File.join(Dir.pwd, 'Makefile')
  if File.exist?(makefile_path)
    manifest_path = File.expand_path(__dir__)
    contents = File.read(makefile_path)
    contents.gsub!(/^RB_SYS_CARGO_MANIFEST_DIR \?=.*$/, "RB_SYS_CARGO_MANIFEST_DIR ?= #{manifest_path}")
    File.write(makefile_path, contents)
  end
rescue LoadError => e
  # rb_sys not available
  create_noop_makefile("Skipping native extension (rb_sys gem not available: #{e.message})")
rescue StandardError => e
  # Any other compilation setup failure (Rust compilation errors, Makefile generation, etc.)
  create_noop_makefile("Skipping native extension (compilation setup failed: #{e.message})")
end
