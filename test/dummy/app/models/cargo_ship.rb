# frozen_string_literal: true

class CargoShip < BaseShip
  attr_reader :cargo_capacity, :current_cargo

  def initialize(name, registry_number, capacity = 50_000)
    super(name, registry_number)
    @cargo_capacity = capacity
    @current_cargo = []
  end

  # Cargo-specific circuits
  circuit :cargo_bay do
    threshold failures: 10, within: 300 # Very tolerant - cargo operations can retry
    reset_after 120
    timeout 30 # Loading/unloading takes time

    fallback { use_manual_cargo_handling }

    on_open { log_event('Cargo bay systems offline') }
  end

  circuit :refrigeration do
    threshold failures: 1, within: 600 # Critical for perishables
    reset_after 300

    fallback { activate_backup_cooling }

    on_open { log_event('ALERT: Refrigeration systems failing!') }
  end

  circuit :docking_clamps do
    threshold failures: 5, within: 120
    reset_after 60
    timeout 10

    fallback { use_magnetic_locks }
  end

  # Override life support for larger crew and cargo areas
  circuit :life_support do
    threshold failures: 5, within: 120 # More redundancy for larger ship
    reset_after 60
    timeout 10

    fallback { activate_zone_isolation }

    on_open { log_event('Life support failing - isolating cargo bays') }
  end

  def load_cargo(manifest)
    circuit(:cargo_bay).wrap do
      circuit(:docking_clamps).wrap do
        raise 'Cargo capacity exceeded' if @current_cargo.sum { |c| c[:weight] } + manifest[:weight] > @cargo_capacity

        @current_cargo << manifest
        "Cargo loaded: #{manifest[:description]} (#{manifest[:weight]} tons)"
      end
    end
  end

  def unload_cargo(cargo_id)
    circuit(:cargo_bay).wrap do
      cargo = @current_cargo.find { |c| c[:id] == cargo_id }
      raise 'Cargo not found' unless cargo

      @current_cargo.delete(cargo)
      "Cargo unloaded: #{cargo[:description]}"
    end
  end

  def refrigerate_cargo
    circuit(:refrigeration).wrap do
      perishables = @current_cargo.select { |c| c[:perishable] }
      "Refrigerating #{perishables.count} perishable items at -20°C"
    end
  end

  def dock_at_station(station_name)
    circuit(:docking_clamps).wrap do
      "Successfully docked at #{station_name}"
    end
  end

  def cargo_manifest
    circuit(:cargo_bay).wrap do
      {
        total_weight: @current_cargo.sum { |c| c[:weight] },
        item_count: @current_cargo.count,
        capacity_used: (@current_cargo.sum { |c| c[:weight] }.to_f / @cargo_capacity * 100).round(2)
      }
    end
  end

  protected

  def use_manual_cargo_handling
    log_event('Switching to manual cargo operations')
    'Manual cargo handling - operations slowed by 75%'
  end

  def activate_backup_cooling
    log_event('Backup cooling systems engaged')
    'Emergency cooling at 60% efficiency'
  end

  def use_magnetic_locks
    log_event('Magnetic docking locks engaged')
    'Magnetic locks active - limited mobility'
  end

  def activate_zone_isolation
    log_event('Isolating cargo bays from life support')
    'Crew areas sealed - cargo bays on minimal life support'
  end
end
