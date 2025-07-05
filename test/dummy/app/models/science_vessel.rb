# frozen_string_literal: true

class ScienceVessel < BaseShip
  attr_reader :research_labs, :probe_inventory

  def initialize(name, registry_number)
    super
    @research_labs = %i[xenobiology astrophysics quantum_mechanics]
    @probe_inventory = 20
  end

  # Science-specific circuits
  circuit :sensor_array do
    threshold failures: 1, within: 30 # Very sensitive equipment
    reset_after 90 # Takes time to recalibrate
    timeout 5

    fallback { use_basic_sensors }

    on_open { log_event('Advanced sensors offline - research capability limited') }
    on_half_open { log_event('Recalibrating sensor array...') }
  end

  circuit :laboratory do
    threshold failures: 3, within: 180
    reset_after 120
    timeout 60 # Experiments take time

    fallback { pause_experiments }

    on_open { log_event('Laboratory systems offline - experiments suspended') }
  end

  circuit :probe_launcher do
    threshold failures: 5, within: 300
    reset_after 45
    timeout 10

    fallback { prepare_manual_launch }
  end

  circuit :containment_field do
    threshold failures: 1, within: 3600 # EXTREMELY critical
    reset_after 600 # Thorough safety checks needed

    fallback { emergency_containment_protocol }

    on_open { log_event('DANGER: Containment field breach!') }
  end

  def scan_anomaly(anomaly_type)
    circuit(:sensor_array).wrap do
      "Scanning #{anomaly_type} anomaly... Fascinating data collected!"
    end
  end

  def conduct_experiment(experiment_name, lab = :xenobiology)
    circuit(:laboratory).wrap do
      circuit(:containment_field).wrap do
        raise 'Invalid laboratory' unless @research_labs.include?(lab)

        "Experiment '#{experiment_name}' completed in #{lab} lab"
      end
    end
  end

  def launch_probe(target)
    circuit(:probe_launcher).wrap do
      raise 'No probes remaining' if @probe_inventory <= 0

      @probe_inventory -= 1
      "Scientific probe launched toward #{target}. #{@probe_inventory} probes remaining"
    end
  end

  def analyze_sample(sample_id)
    circuit(:laboratory).wrap do
      circuit(:sensor_array).wrap do
        "Sample #{sample_id} analysis complete: Unknown organic compound detected"
      end
    end
  end

  def establish_containment(hazard_level)
    circuit(:containment_field).wrap do
      "Level #{hazard_level} containment field established"
    end
  end

  protected

  def use_basic_sensors
    log_event('Falling back to basic sensor package')
    'Basic sensors only - 20% effectiveness'
  end

  def pause_experiments
    log_event('All experiments paused for safety')
    'Experiments suspended - data preserved'
  end

  def prepare_manual_launch
    log_event('Preparing for manual probe launch')
    'Manual probe launch prepared - 5 minute delay'
  end

  def emergency_containment_protocol
    log_event('EMERGENCY: Ejecting all hazardous samples!')
    'All samples ejected to space - laboratory sealed'
  end
end
