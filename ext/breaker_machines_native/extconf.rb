# frozen_string_literal: true

# Skip native extension compilation on JRuby
if RUBY_ENGINE == 'jruby'
  puts 'Skipping native extension compilation on JRuby'
  puts 'BreakerMachines will use pure Ruby backend'
  makefile_content = "all:\n\t@echo 'Skipping native extension on JRuby'\n" \
                     "install:\n\t@echo 'Skipping native extension on JRuby'\n"
  File.write('Makefile', makefile_content)
  exit 0
end

# Check if Cargo is available
def cargo_available?
  system('cargo --version > /dev/null 2>&1')
end

unless cargo_available?
  warn 'WARNING: Cargo (Rust toolchain) not found!'
  warn 'BreakerMachines will fall back to pure Ruby backend.'
  warn 'To enable native performance, install Rust from https://rustup.rs'

  # Create a dummy Makefile that does nothing
  makefile_content = "all:\n\t@echo 'Skipping native extension (Cargo not found)'\n" \
                     "install:\n\t@echo 'Skipping native extension (Cargo not found)'\n"
  File.write('Makefile', makefile_content)
  exit 0
end

# Use rb_sys to compile the Rust extension
require 'mkmf'
require 'rb_sys/mkmf'

create_rust_makefile('breaker_machines_native/breaker_machines_native') do |r|
  # Set the path to the FFI crate (relative to current directory)
  r.ext_dir = 'ffi'

  # Profile configuration
  r.profile = ENV.fetch('RB_SYS_CARGO_PROFILE', :release).to_sym
end
