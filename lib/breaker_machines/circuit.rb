# frozen_string_literal: true

module BreakerMachines
  class Circuit
    include Circuit::Base
    include StateManagement
  end
end
