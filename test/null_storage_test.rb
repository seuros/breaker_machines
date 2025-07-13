# frozen_string_literal: true

require 'test_helper'

class NullStorageTest < ActiveSupport::TestCase
  def setup
    @storage = BreakerMachines::Storage::Null.new
    @circuit_name = :test_circuit
  end

  def test_record_success_is_noop
    # Should not raise any errors
    assert_nothing_raised do
      @storage.record_success(@circuit_name, 0.5)
    end
  end

  def test_record_failure_is_noop
    # Should not raise any errors
    assert_nothing_raised do
      @storage.record_failure(@circuit_name, 0.1)
    end
  end

  def test_counts_always_return_zero
    # Record some events (which do nothing)
    5.times { @storage.record_success(@circuit_name) }
    3.times { @storage.record_failure(@circuit_name) }

    # Counts should always be zero
    assert_equal 0, @storage.success_count(@circuit_name)
    assert_equal 0, @storage.failure_count(@circuit_name)
    assert_equal 0, @storage.success_count(@circuit_name, 60)
    assert_equal 0, @storage.failure_count(@circuit_name, 60)
  end

  def test_status_operations_are_noop
    # Set status does nothing
    @storage.set_status(@circuit_name, :open, Time.now.to_f)

    # Get status returns nil
    assert_nil @storage.get_status(@circuit_name)
  end

  def test_clear_is_noop
    assert_nothing_raised do
      @storage.clear(@circuit_name)
    end
  end

  def test_event_log_returns_empty_array
    assert_empty @storage.event_log(@circuit_name)
    assert_empty @storage.event_log(@circuit_name, 100)
  end

  def test_record_event_with_details_is_noop
    assert_nothing_raised do
      @storage.record_event_with_details(@circuit_name, :failure, 0.5, error: 'Test error')
    end
  end

  def test_circuit_with_null_storage_works
    circuit = BreakerMachines::Circuit.new(:null_test, {
                                             storage: @storage,
                                             failure_threshold: 2,
                                             failure_window: 60
                                           })

    # Circuit should work normally, just without metrics
    assert_predicate circuit, :closed?

    # Failures won't be counted, so circuit won't open based on count
    # But it can still be manually controlled
    circuit.send(:trip)

    assert_predicate circuit, :open?

    circuit.send(:reset)

    assert_predicate circuit, :closed?
  end
end
