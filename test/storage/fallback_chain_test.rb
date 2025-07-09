# frozen_string_literal: true

require 'test_helper'

class FallbackChainTest < ActiveSupport::TestCase
  def setup
    # Use memory cache store for testing since null_store doesn't actually store anything
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @config = [
      { backend: :cache, timeout: 10 },    # Use cache (can be shared)
      { backend: :null, timeout: 5 }       # Null as final fallback
    ]
    @chain = BreakerMachines::Storage::FallbackChain.new(@config)
  end

  def teardown
    @chain&.cleanup!
    Rails.cache = ActiveSupport::Cache::NullStore.new
  end

  def test_successful_operation_on_first_backend
    @chain.set_status(:test_circuit, :closed)
    result = @chain.get_status(:test_circuit)

    assert_not_nil result
    assert_equal :closed, result[:status]
  end

  def test_fallback_to_second_backend_when_first_fails
    # Mock first backend to fail
    cache_backend = @chain.send(:get_backend_instance, :cache)
    cache_backend.define_singleton_method(:with_timeout) do |_timeout_ms|
      raise BreakerMachines::StorageTimeoutError, 'Simulated timeout'
    end

    # This should succeed on the null backend
    @chain.set_status(:test_circuit, :open)
    # Null backend doesn't actually store anything, so this will return nil
    result = @chain.get_status(:test_circuit)

    assert_nil result
  end

  def test_all_backends_unhealthy_raises_error
    # Create a chain with only one backend that we'll mark as unhealthy
    single_config = [{ backend: :cache, timeout: 5 }]
    single_chain = BreakerMachines::Storage::FallbackChain.new(single_config)

    # Mark backend as unhealthy by simulating failures
    backend_type = :cache
    3.times do
      single_chain.send(:record_backend_failure,
                        backend_type,
                        StandardError.new('test error'),
                        10)
    end

    # Should raise error since all backends are unhealthy
    assert_raises BreakerMachines::StorageError do
      single_chain.get_status(:test_circuit)
    end

    single_chain.cleanup!
  end

  def test_cleanup_resets_state
    @chain.set_status(:test_circuit, :closed)

    # Record some failures
    @chain.send(:record_backend_failure, :cache, StandardError.new('test'), 10)

    # Cleanup should reset everything
    @chain.cleanup!

    # Should be able to use the chain again
    @chain.set_status(:test_circuit, :open)
    result = @chain.get_status(:test_circuit)

    assert_not_nil result
    assert_equal :open, result[:status]
  end
end
