# frozen_string_literal: true

# Simulated space systems for testing
module SpaceflightSystems
  class WarpDriveError < StandardError; end
  class ReactorOverloadError < StandardError; end
  class NavigationSystemOfflineError < StandardError; end

  class WarpDrive
    def self.engage(destination)
      # Simulate warp drive behavior
      { status: 'engaged', destination: destination, speed: 'warp_9' }
    end
  end

  class FusionReactor
    def self.ignite(power_level)
      { status: 'online', power_output: power_level, temperature: 'optimal' }
    end
  end

  class NavigationComputer
    def self.calculate_route(_coordinates)
      { route: 'calculated', distance: '42.7 parsecs', eta: '3.2 hours' }
    end
  end
end
