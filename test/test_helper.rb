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

# Load dummy app models in dependency order
require_relative 'dummy/app/models/spaceflight_systems'
require_relative 'dummy/app/models/base_ship'
require_relative 'dummy/app/models/base_spaceship'
require_relative 'dummy/app/models/battle_ship'
require_relative 'dummy/app/models/cargo_ship'
require_relative 'dummy/app/models/explorer_ship'
require_relative 'dummy/app/models/fighter'
require_relative 'dummy/app/models/science_vessel'
require_relative 'dummy/app/models/spaceship'
require_relative 'dummy/app/models/corellian_freighter'
require_relative 'dummy/app/models/rmns_atlas_monkey'
