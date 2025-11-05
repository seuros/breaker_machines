# frozen_string_literal: true

require_relative 'native_extension'

# Load the native extension if available
BreakerMachines::NativeExtension.load!
