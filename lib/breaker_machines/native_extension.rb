# frozen_string_literal: true

module BreakerMachines
  # Handles loading and status of the optional native extension
  module NativeExtension
    class << self
      # Load the native extension and set availability flag
      # Can be called multiple times - subsequent calls are memoized
      def load!
        return @loaded if defined?(@loaded)

        @loaded = true
        require 'breaker_machines_native/breaker_machines_native'
        BreakerMachines.instance_variable_set(:@native_available, true)
        BreakerMachines.log(:info, 'Native extension loaded successfully')
        true
      rescue LoadError => e
        @loaded = false
        BreakerMachines.instance_variable_set(:@native_available, false)

        # Only log if it's not JRuby (expected failure) and logging is enabled
        if RUBY_ENGINE != 'jruby'
          BreakerMachines.log(:warn, "Native extension not available: #{e.message}")
          BreakerMachines.log(:warn, 'Using pure Ruby backend (slower but functional)')
        end

        false
      end

      # Check if load was attempted
      def loaded?
        defined?(@loaded) && @loaded
      end
    end
  end
end
