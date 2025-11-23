# frozen_string_literal: true

require 'rbconfig'
require 'active_support/core_ext/object/blank'

module BreakerMachines
  # Handles loading and status of the optional native extension
  module NativeExtension
    class << self
      # Load the native extension and set availability flag
      # Can be called multiple times - subsequent calls are memoized
      def load!
        return @loaded if defined?(@loaded)

        # Native extension is opt-in: only load if explicitly enabled
        unless ENV['BREAKER_MACHINES_NATIVE'] == '1'
          @loaded = false
          BreakerMachines.instance_variable_set(:@native_available, false)
          return false
        end

        errors = []

        native_library_candidates.each do |require_path|
          try_require(require_path)
          @loaded = true
          BreakerMachines.instance_variable_set(:@native_available, true)
          BreakerMachines.log(:info, "Native extension loaded successfully (#{require_path})")
          return true
        rescue LoadError => e
          errors << "#{require_path}: #{e.message}"
        end

        @loaded = false
        BreakerMachines.instance_variable_set(:@native_available, false)
        BreakerMachines.log(:warn, "Native extension not available: #{errors.join(' | ')}") unless errors.empty?

        false
      end

      # Check if load was attempted
      def loaded?
        defined?(@loaded) && @loaded
      end

      private

      def native_library_candidates
        dlext = RbConfig::CONFIG['DLEXT']
        base_dir = File.expand_path('../breaker_machines_native', __dir__)
        ruby_version = RbConfig::CONFIG['ruby_version']
        arch = RbConfig::CONFIG['arch']
        platform = Gem::Platform.local.to_s

        matches = Dir.glob(File.join(base_dir, '**', "breaker_machines_native.#{dlext}"))

        prioritized = matches.sort_by do |path|
          score = 0
          score -= 3 if path.include?(ruby_version)
          score -= 2 if path.include?(arch)
          score -= 1 if path.include?(platform)
          [score, path]
        end

        candidates = prioritized.map { |full_path| require_path_for(full_path, dlext) }.presence
        candidates ||= ['breaker_machines_native/breaker_machines_native']
        candidates.uniq
      end

      def require_path_for(full_path, dlext)
        root = File.expand_path('..', __dir__)
        relative = full_path.sub(%r{^#{Regexp.escape(root)}/?}, '')
        relative.sub(/\.#{Regexp.escape(dlext)}\z/, '')
      end

      def try_require(require_path)
        require require_path
      end
    end
  end
end
