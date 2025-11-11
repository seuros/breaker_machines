# frozen_string_literal: true

require_relative 'native_extension'

# Load the native extension if available
if BreakerMachines::NativeExtension.load!
  # Only load Storage::Native if native extension loaded successfully
  # This prevents referencing BreakerMachinesNative::Storage when not available
  require_relative 'storage/native'
end
