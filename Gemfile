# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'activesupport', '>= 8.1' # Cache storage and notifications tests
gem 'async', '~> 2.31' # AsyncCircuit and fiber-safe tests
gem 'minitest', '~> 6.0'
gem 'padded_cell', '~> 0.2'
gem 'rake', '~> 13.0'
gem 'rake-compiler', '~> 1.3'
gem 'rbs', '~> 3.0'

# Untracked local overrides (sibling checkouts as path gems), never committed.
local = File.expand_path('Gemfile.local', __dir__)
eval_gemfile local if File.exist?(local)
