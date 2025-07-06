# frozen_string_literal: true

require 'test_helper'

class TestDSLValidation < ActiveSupport::TestCase
  def test_validates_positive_failure_threshold
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          threshold failures: -1, within: 60
        end
      end
    end

    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          threshold failures: 0, within: 60
        end
      end
    end
  end

  def test_validates_failure_rate_range
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          threshold failure_rate: -0.1, within: 60
        end
      end
    end

    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          threshold failure_rate: 1.1, within: 60
        end
      end
    end

    # Valid rates should not raise
    Class.new do
      include BreakerMachines::DSL

      circuit :test do
        threshold failure_rate: 0.0, within: 60
      end

      circuit :test2 do
        threshold failure_rate: 0.5, within: 60
      end

      circuit :test3 do
        threshold failure_rate: 1.0, within: 60
      end
    end
  end

  def test_validates_positive_minimum_calls
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          threshold failure_rate: 0.5, minimum_calls: 0, within: 60
        end
      end
    end
  end

  def test_validates_positive_within_window
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          threshold failures: 5, within: -10
        end
      end
    end
  end

  def test_validates_positive_success_threshold
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          threshold failures: 5, within: 60, successes: -1
        end
      end
    end
  end

  def test_validates_positive_reset_timeout
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          reset_after(-30)
        end
      end
    end
  end

  def test_validates_jitter_range
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          reset_after 60, jitter: -0.1
        end
      end
    end

    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          reset_after 60, jitter: 1.5
        end
      end
    end

    # Valid jitter should not raise
    Class.new do
      include BreakerMachines::DSL

      circuit :test do
        reset_after 60, jitter: 0.0
      end

      circuit :test2 do
        reset_after 60, jitter: 0.25
      end

      circuit :test3 do
        reset_after 60, jitter: 1.0
      end
    end
  end

  def test_validates_non_negative_timeout
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          timeout(-5)
        end
      end
    end

    # Zero timeout should be allowed (means no timeout)
    Class.new do
      include BreakerMachines::DSL

      circuit :test do
        timeout 0
      end
    end
  end

  def test_validates_positive_half_open_requests
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          half_open_requests 0
        end
      end
    end

    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          half_open_requests(-1)
        end
      end
    end
  end

  def test_validates_positive_max_concurrent
    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          max_concurrent 0
        end
      end
    end

    assert_raises(BreakerMachines::ConfigurationError) do
      Class.new do
        include BreakerMachines::DSL

        circuit :test do
          max_concurrent(-10)
        end
      end
    end
  end

  def test_accepts_valid_configuration
    # This should not raise any errors
    klass = Class.new do
      include BreakerMachines::DSL

      circuit :valid_circuit do
        threshold failures: 5, within: 60, successes: 2
        reset_after 30, jitter: 0.25
        timeout 10
        half_open_requests 3
        max_concurrent 50

        fallback { 'fallback value' }
      end
    end

    instance = klass.new
    config = instance.circuit(:valid_circuit).instance_variable_get(:@config)

    assert_equal 5, config[:failure_threshold]
    assert_equal 60, config[:failure_window]
    assert_equal 2, config[:success_threshold]
    assert_equal 30, config[:reset_timeout]
    assert_in_delta(0.25, config[:reset_timeout_jitter])
    assert_equal 10, config[:timeout]
    assert_equal 3, config[:half_open_calls]
    assert_equal 50, config[:max_concurrent]
  end
end
