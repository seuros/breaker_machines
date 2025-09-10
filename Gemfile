# frozen_string_literal: true

source 'https://rubygems.org'

# Use local state_machines gem with JRuby fix
gem 'state_machines'

# Specify your gem's dependencies in breaker_machines.gemspec
gemspec

gem 'irb'
gem 'rake', '~> 13.0'

gem 'activesupport', '~> 8.0'
gem 'minitest', '~> 5.16'
gem 'rubocop', '~> 1.77'
gem 'rubocop-minitest', '~> 0.30'
gem 'rubocop-rake', '~> 0.6'

# Optional dependency for fiber-safe mode tests (MRI only)

# Platform specific gems (MRI Ruby only)
platforms :mri do
  gem 'activerecord', '~> 8.0'
  gem 'async', '~> 2.0'
  gem 'railties', '~> 8.0'
  gem 'rbs', '~> 3.0'
  gem 'sqlite3', '~> 2.0'
  gem 'state_machines-activerecord'
end
