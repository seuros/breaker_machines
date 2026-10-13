# frozen_string_literal: true

module BreakerMachines
  class Circuit
    include Circuit::Base
    include StateManagement

    def initialize(...)
      super
      restore_status_from_storage if @storage
      BreakerMachines::Registry.instance.register(self) unless @config[:auto_register] == false
    end
  end
end
