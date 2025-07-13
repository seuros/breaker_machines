# frozen_string_literal: true

module BreakerMachines
  module DSL
    # Builder for hedged request configuration
    class HedgedBuilder
      def initialize(config)
        @config = config
        @config[:hedged_requests] = true
      end

      def delay(milliseconds)
        @config[:hedging_delay] = milliseconds
      end

      def max_requests(count)
        @config[:max_hedged_requests] = count
      end
    end
  end
end
