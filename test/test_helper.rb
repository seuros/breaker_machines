# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'breaker_machines'

require 'minitest/autorun'
require 'active_support/test_case'

# Require async for fiber tests
require 'async'

# Suppress notifications during tests unless explicitly testing them
BreakerMachines.config.log_events = false

# Disable fiber_safe by default during tests
BreakerMachines.config.fiber_safe = false

# Load Rails environment
ENV['RAILS_ENV'] ||= 'test'
require_relative 'dummy/config/environment'
require 'rails/test_help'
require 'state_machines/integrations/active_record'

# Load the schema
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.verbose = false
load File.expand_path('dummy/db/schema.rb', __dir__)
