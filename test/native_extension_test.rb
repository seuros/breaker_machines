# frozen_string_literal: true

require 'test_helper'

class NativeExtensionTest < ActiveSupport::TestCase
  def setup
    @original_loaded = if BreakerMachines::NativeExtension.instance_variable_defined?(:@loaded)
                         BreakerMachines::NativeExtension.instance_variable_get(:@loaded)
                       else
                         :__undefined__
                       end
    @original_native_available = BreakerMachines.native_available?
  end

  def teardown
    if @original_loaded == :__undefined__
      if BreakerMachines::NativeExtension.instance_variable_defined?(:@loaded)
        BreakerMachines::NativeExtension.remove_instance_variable(:@loaded)
      end
    else
      BreakerMachines::NativeExtension.instance_variable_set(:@loaded, @original_loaded)
    end
    BreakerMachines.instance_variable_set(:@native_available, @original_native_available)
  end

  def test_prefers_versioned_native_library_when_present
    skip if RUBY_ENGINE == 'jruby'

    with_native_extension_enabled do
      reset_native_extension_state

      ruby_version = RbConfig::CONFIG['ruby_version']
      arch = RbConfig::CONFIG['arch']

      attempts = []

      candidates = [
        File.join('breaker_machines_native', ruby_version, arch, 'breaker_machines_native'),
        File.join('breaker_machines_native', ruby_version, 'breaker_machines_native'),
        'breaker_machines_native/breaker_machines_native'
      ]

      BreakerMachines::NativeExtension.stub(:native_library_candidates, candidates) do
        BreakerMachines::NativeExtension.stub(:try_require, lambda { |path|
          attempts << path
          raise LoadError, 'wrong arch' unless path.include?(ruby_version)

          true
        }) do
          assert BreakerMachines::NativeExtension.load!
        end
      end

      expected_first = File.join('breaker_machines_native', ruby_version, arch, 'breaker_machines_native')
      expected_second = File.join('breaker_machines_native', ruby_version, 'breaker_machines_native')

      assert_equal expected_first, attempts.first if attempts.include?(expected_first)
      assert_equal expected_second, attempts.first unless attempts.include?(expected_first)

      assert_predicate BreakerMachines, :native_available?
    end
  end

  private

  def with_native_extension_enabled
    previous = ENV['BREAKER_MACHINES_NATIVE']
    ENV['BREAKER_MACHINES_NATIVE'] = '1'
    yield
  ensure
    if previous.nil?
      ENV.delete('BREAKER_MACHINES_NATIVE')
    else
      ENV['BREAKER_MACHINES_NATIVE'] = previous
    end
  end

  def reset_native_extension_state
    if BreakerMachines::NativeExtension.instance_variable_defined?(:@loaded)
      BreakerMachines::NativeExtension.remove_instance_variable(:@loaded)
    end
    BreakerMachines.instance_variable_set(:@native_available, false)
  end
end
