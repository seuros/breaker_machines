# frozen_string_literal: true

source 'https://rubygems.org'

# Use local state_machines gem with JRuby fix
gem 'state_machines'

# Specify your gem's dependencies in breaker_machines.gemspec
gemspec

gem 'rake', '~> 13.0'

gem 'minitest', '~> 6.0'
# Minitest 6 extracted minitest/mock; ActiveSupport::TestCase still requires it.
gem 'minitest-mock', '~> 5.27'

# Optional dependency for fiber-safe mode tests (MRI only)

# Platform specific gems (MRI Ruby only)
platforms :mri do
  gem 'irb'
  gem 'padded_cell', '~> 0.2' # Fork-per-test runner for `rake test` (CRuby only)

  if ENV['ACTIVERECORD_VERSION'] == 'edge'
    gem 'activerecord', github: 'rails/rails', branch: 'main'
    gem 'railties', github: 'rails/rails', branch: 'main'
  else
    rails_version = ENV.fetch('ACTIVERECORD_VERSION', '8.1')
    gem 'activerecord', "~> #{rails_version}.0"
    gem 'railties', "~> #{rails_version}.0"
  end
  gem 'async', '~> 2.31.0'
  gem 'sqlite3', '~> 2.0'
  gem 'state_machines-activerecord'
end
