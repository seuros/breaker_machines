# frozen_string_literal: true
require 'mkmf'
require 'pathname'
require 'rb_sys/mkmf'
create_rust_makefile('breaker_machines_native/breaker_machines_native') do |extension|
  extension.ext_dir = Pathname(__dir__).relative_path_from(Pathname(Dir.pwd)).to_s
  extension.profile = ENV.fetch('RB_SYS_CARGO_PROFILE', :release).to_sym
end
makefile = File.join(Dir.pwd, 'Makefile')
manifest_dir = File.expand_path(__dir__)
patched = File.read(makefile).gsub(/^RB_SYS_CARGO_MANIFEST_DIR \?=.*$/, "RB_SYS_CARGO_MANIFEST_DIR ?= #{manifest_dir}")
File.write(makefile, patched)
