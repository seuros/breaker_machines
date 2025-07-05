# frozen_string_literal: true

require 'test_helper'

class TestStorageBackends < ActiveSupport::TestCase
  class SpaceProbe
    include BreakerMachines::DSL

    def self.with_storage(storage)
      circuit :telemetry do
        threshold failures: 2, within: 5
        storage storage
      end
    end

    def send_telemetry(&)
      circuit(:telemetry).call(&)
    end
  end

  def test_circuit_works_with_memory_storage
    probe = Class.new(SpaceProbe) do
      with_storage BreakerMachines::Storage::Memory.new
    end.new

    # Should work normally
    result = probe.send_telemetry { 'Signal sent' }

    assert_equal 'Signal sent', result

    # Trigger failures
    2.times do
      assert_raises(RuntimeError) do
        probe.send_telemetry { raise 'Antenna malfunction' }
      end
    end

    # Circuit should be open
    assert_raises(BreakerMachines::CircuitOpenError) do
      probe.send_telemetry { "This won't execute" }
    end
  end

  def test_circuit_works_with_bucket_memory_storage
    probe = Class.new(SpaceProbe) do
      with_storage BreakerMachines::Storage::BucketMemory.new
    end.new

    # Should work normally
    result = probe.send_telemetry { 'Signal sent' }

    assert_equal 'Signal sent', result

    # Trigger failures
    2.times do
      assert_raises(RuntimeError) do
        probe.send_telemetry { raise 'Antenna malfunction' }
      end
    end

    # Circuit should be open
    assert_raises(BreakerMachines::CircuitOpenError) do
      probe.send_telemetry { "This won't execute" }
    end
  end

  def test_default_storage_is_bucket_memory
    probe = Class.new(SpaceProbe) do
      circuit :sensors do
        threshold failures: 2
      end
    end.new

    # Get the circuit instance
    circuit = probe.circuit(:sensors)

    # Check that default storage is BucketMemory
    assert_instance_of BreakerMachines::Storage::BucketMemory,
                       circuit.instance_variable_get(:@storage)
  end
end
