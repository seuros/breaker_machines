# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'

# Ractor scenarios run in a child Ruby that loads only the native extension.
# Once a Ractor has run, Ruby 4.0 can abort later in unrelated code that reads
# class variables (`[BUG] should have cvar cache entry`, seen in i18n and
# ActionView), so Ractors must never start inside the shared test process.
class NativeRactorTest < ActiveSupport::TestCase
  def setup
    skip 'Native extension not available' unless BreakerMachines.native_available?
  end

  def test_circuit_runs_inside_a_ractor
    assert_equal 'open', in_ractor_process(<<~RUBY)
      state = Ractor.new do
        circuit = BreakerMachinesNative::Circuit.new('ractor', { failure_threshold: 2 })
        2.times { circuit.record_failure(0.01) }
        circuit.state_name
      end.value
      print state
    RUBY
  end

  def test_frozen_storage_is_shared_across_ractors
    assert_equal 'true 100', in_ractor_process(<<~RUBY)
      storage = Ractor.make_shareable(BreakerMachinesNative::Storage.new)
      workers = Array.new(4) do
        Ractor.new(storage) do |shared|
          25.times { shared.record_failure('shared', 0.01) }
        end
      end
      workers.each(&:join)
      print Ractor.shareable?(storage), ' ', storage.failure_count('shared', 60.0)
    RUBY
  end

  def test_circuit_is_not_shareable
    assert_equal 'Ractor::Error', in_ractor_process(<<~RUBY)
      circuit = BreakerMachinesNative::Circuit.new('local', {})
      begin
        Ractor.make_shareable(circuit)
        print 'shareable'
      rescue Ractor::Error => e
        print e.class
      end
    RUBY
  end

  def test_config_rejects_wrong_types
    assert_raises(TypeError) do
      BreakerMachinesNative::Circuit.new('typed', { failure_threshold: 'five' })
    end
  end

  private

  # Runs `script` in a fresh Ruby with the same native build loaded and
  # returns its stdout; fails the test with stderr if the child fails.
  def in_ractor_process(script)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-W:no-experimental', '-e', "require #{native_library.dump}", '-e', script
    )

    assert_predicate status, :success?, "child Ruby failed:\n#{stderr}"
    stdout
  end

  def native_library
    $LOADED_FEATURES.find { |path| File.basename(path, '.*') == 'breaker_machines_native' } ||
      flunk('native extension is reported available but is not loaded')
  end
end
