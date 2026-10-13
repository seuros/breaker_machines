# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Protection adds `protect`, which wraps selected public methods of an
    # object so that each call runs through this circuit's `call`.
    module Protection
      def protect(object, methods:)
        Proxy.new(object, circuit: self, methods:)
      end
    end
  end
end
