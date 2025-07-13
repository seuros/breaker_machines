# frozen_string_literal: true

module BreakerMachines
  module DSL
    # Builder for cascading circuit breaker configuration
    class CascadingCircuitBuilder < CircuitBuilder
      def cascades_to(*circuit_names)
        @config[:cascades_to] = circuit_names.flatten
      end

      def emergency_protocol(protocol_name)
        @config[:emergency_protocol] = protocol_name
      end

      def on_cascade(&block)
        @config[:on_cascade] = block
      end
    end
  end
end
