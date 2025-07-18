# frozen_string_literal: true

require 'concurrent-ruby'

module BreakerMachines
  class Circuit
    include StateManagement
    include Configuration
    include Execution
    include Circuit::HedgedExecution
    include Introspection
    include Callbacks
  end
end
