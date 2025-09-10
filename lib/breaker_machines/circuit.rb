# frozen_string_literal: true

require_relative 'circuit/base'

module BreakerMachines
  class Circuit
    include Circuit::Base
    include StateManagement
  end
end
