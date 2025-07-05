# frozen_string_literal: true

require 'test_helper'

class TestBreakerMachines < ActiveSupport::TestCase
  def test_that_it_has_a_version_number
    refute_nil ::BreakerMachines::VERSION
  end

  def test_global_configuration
    original_threshold = BreakerMachines.config.default_failure_threshold

    BreakerMachines.configure do |config|
      config.default_failure_threshold = 10
      config.default_reset_timeout = 120
    end

    assert_equal 10, BreakerMachines.config.default_failure_threshold
    assert_equal 120, BreakerMachines.config.default_reset_timeout
  ensure
    BreakerMachines.config.default_failure_threshold = original_threshold
  end
end
