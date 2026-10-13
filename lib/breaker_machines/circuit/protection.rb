# frozen_string_literal: true

module BreakerMachines
  class Circuit
    module Protection
      def protect(object, methods:)
        Proxy.new(object, circuit: self, methods:)
      end
    end
  end
end
