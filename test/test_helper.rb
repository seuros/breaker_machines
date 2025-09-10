# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'breaker_machines'

require 'minitest/autorun'
require 'active_support/test_case'

# Require async for fiber tests
begin
  require 'async'
rescue LoadError
  # Async not available (e.g., on JRuby)
end

# Suppress notifications during tests unless explicitly testing them
BreakerMachines.config.log_events = false

# Disable fiber_safe by default during tests
BreakerMachines.config.fiber_safe = false

# Disable logger output during tests
BreakerMachines.logger = Logger.new(nil)

# Load Rails environment
begin
  ENV['RAILS_ENV'] ||= 'test'
  require_relative 'dummy/config/environment'
  require 'rails/test_help'
  require 'state_machines/integrations/active_record'

  # Load the schema
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  ActiveRecord::Schema.verbose = false
  load File.expand_path('dummy/db/schema.rb', __dir__)
rescue LoadError
  # Rails not available (e.g., on JRuby)
end

# Skip platform-dependent tests helper
module RailsTestSkipper
  def skip_rails_dependent_test
    # This is a no-op when Rails is available
  end

  def skip_activerecord_dependent_test
    skip 'ActiveRecord not available' unless defined?(ActiveRecord)
  end

  def skip_async_dependent_test
    skip 'Async gem not available' unless defined?(Async)
  end
end

# Global teardown to ensure circuit registry is cleared between ALL tests
module ActiveSupport
  class TestCase
    include RailsTestSkipper

    # Disable parallel tests globally to prevent DRb connection pool corruption
    # with FallbackChain and other storage timeout behaviors
    parallelize(workers: 1)

    def teardown
      super
      # Clear the circuit registry after every test to prevent state leakage
      BreakerMachines.registry.clear
      # Clear Rails cache to prevent storage state leakage
      Rails.cache.clear if defined?(Rails)
    end
  end
end
