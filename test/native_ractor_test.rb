# frozen_string_literal: true

require 'test_helper'

class NativeRactorTest < ActiveSupport::TestCase
  def setup
    skip 'Native extension not available' unless BreakerMachines.native_available?
    @experimental = Warning[:experimental]
    Warning[:experimental] = false
  end

  def teardown
    Warning[:experimental] = @experimental unless @experimental.nil?
  end

  def test_circuit_runs_inside_a_ractor
    state = Ractor.new do
      circuit = BreakerMachinesNative::Circuit.new('ractor', { failure_threshold: 2 })
      2.times { circuit.record_failure(0.01) }
      circuit.state_name
    end.value

    assert_equal 'open', state
  end

  def test_frozen_storage_is_shared_across_ractors
    storage = Ractor.make_shareable(BreakerMachinesNative::Storage.new)

    assert_predicate storage, :frozen?
    assert Ractor.shareable?(storage)

    workers = Array.new(4) do
      Ractor.new(storage) do |shared|
        25.times { shared.record_failure('shared', 0.01) }
      end
    end
    workers.each(&:join)

    assert_equal 100, storage.failure_count('shared', 60.0)
  end

  def test_circuit_is_not_shareable
    circuit = BreakerMachinesNative::Circuit.new('local', {})

    assert_raises(Ractor::Error) { Ractor.make_shareable(circuit) }
  end

  def test_config_rejects_wrong_types
    assert_raises(TypeError) do
      BreakerMachinesNative::Circuit.new('typed', { failure_threshold: 'five' })
    end
  end
end
