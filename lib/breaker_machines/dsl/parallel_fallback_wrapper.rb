# frozen_string_literal: true

module BreakerMachines
  module DSL
    # Wrapper to indicate parallel execution for fallbacks
    class ParallelFallbackWrapper
      attr_reader :fallbacks

      def initialize(fallbacks)
        @fallbacks = fallbacks
      end

      def call(error)
        # This will be handled by the circuit's fallback mechanism
        # to execute fallbacks in parallel
        raise NotImplementedError, 'ParallelFallbackWrapper should be handled by Circuit'
      end
    end
  end
end
