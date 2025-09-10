# frozen_string_literal: true

# Helper for running tests on JRuby/TruffleRuby without Rails dependencies

# Skip Rails-dependent tests
module RailsTestSkipper
  def skip_rails_dependent_test
    skip 'Rails not available' unless defined?(Rails)
  end

  def skip_activerecord_dependent_test
    skip 'ActiveRecord not available' unless defined?(ActiveRecord)
  end

  def skip_async_dependent_test
    skip 'Async gem not available' unless defined?(Async)
  end
end

# Include in all test classes
class ActiveSupport::TestCase
  include RailsTestSkipper
end

class Minitest::Test
  include RailsTestSkipper
end
