# frozen_string_literal: true

require 'state_machines'
require 'concurrent-ruby'

module BreakerMachines
  class Circuit
    include StateManagement
    include Configuration
    include Execution
    include HedgedExecution
    include Introspection
    include Callbacks
  end
end
