# frozen_string_literal: true

module BreakerMachines
  # CascadingCircuit extends the base Circuit class with the ability to automatically
  # trip dependent circuits when this circuit opens. This enables sophisticated
  # failure cascade modeling, similar to how critical system failures in a starship
  # would cascade to dependent subsystems.
  #
  # @example Starship network dependency
  #   # Network circuit that cascades to dependent systems
  #   network_circuit = BreakerMachines::CascadingCircuit.new('subspace_network', {
  #     failure_threshold: 1,
  #     cascades_to: ['weapons_targeting', 'navigation_sensors', 'communications'],
  #     emergency_protocol: :red_alert
  #   })
  #
  #   # When network fails, all dependent systems are automatically tripped
  #   network_circuit.call { raise 'Subspace relay offline!' }
  #   # => All dependent circuits are now open
  #
  class CascadingCircuit < Circuit
    attr_reader :dependent_circuits, :emergency_protocol

    def initialize(name, config = {})
      @dependent_circuits = Array(config.delete(:cascades_to))
      @emergency_protocol = config.delete(:emergency_protocol)

      super
    end

    # Override the trip method to include cascading behavior
    def trip!
      result = super
      perform_cascade if result && @dependent_circuits.any?
      result
    end

    # Force cascade failure to all dependent circuits
    def cascade_failure!
      perform_cascade
    end

    # Get the current status of all dependent circuits
    def dependent_status
      return {} if @dependent_circuits.empty?

      @dependent_circuits.each_with_object({}) do |circuit_name, status|
        circuit = BreakerMachines.registry.find(circuit_name)
        status[circuit_name] = circuit ? circuit.status_name : :not_found
      end
    end

    # Check if any dependent circuits are open
    def dependents_compromised?
      @dependent_circuits.any? do |circuit_name|
        circuit = BreakerMachines.registry.find(circuit_name)
        circuit&.open?
      end
    end

    # Summary that includes cascade information
    def summary
      base_summary = super
      return base_summary if @dependent_circuits.empty?

      if @cascade_triggered_at&.value
        compromised_count = dependent_status.values.count(:open)
        " CASCADE TRIGGERED: #{compromised_count}/#{@dependent_circuits.length} dependent systems compromised."
      else
        " Monitoring #{@dependent_circuits.length} dependent systems."
      end

      base_summary + cascade_info_text
    end

    # Provide cascade info for introspection
    def cascade_info
      BreakerMachines::CascadeInfo.new(
        dependent_circuits: @dependent_circuits,
        emergency_protocol: @emergency_protocol,
        cascade_triggered_at: @cascade_triggered_at&.value,
        dependent_status: dependent_status
      )
    end

    private

    def perform_cascade
      return if @dependent_circuits.empty?

      cascade_results = []
      @cascade_triggered_at ||= Concurrent::AtomicReference.new
      @cascade_triggered_at.value = BreakerMachines.monotonic_time

      @dependent_circuits.each do |circuit_name|
        # First try to find circuit in registry
        circuit = BreakerMachines.registry.find(circuit_name)

        # If not found and we have an owner, try to get it from the owner
        if !circuit && @config[:owner]
          owner = @config[:owner]
          # Handle WeakRef if present
          owner = owner.__getobj__ if owner.is_a?(WeakRef)

          circuit = owner.circuit(circuit_name) if owner.respond_to?(:circuit)
        end

        next unless circuit
        next unless circuit.closed? || circuit.half_open?

        # Force the dependent circuit to open
        circuit.force_open!
        cascade_results << circuit_name

        BreakerMachines.instrument('cascade_failure', {
                                     source_circuit: @name,
                                     target_circuit: circuit_name,
                                     emergency_protocol: @emergency_protocol
                                   })
      end

      # Trigger emergency protocol if configured
      trigger_emergency_protocol(cascade_results) if @emergency_protocol && cascade_results.any?

      # Invoke cascade callback if configured
      if @config[:on_cascade]
        begin
          @config[:on_cascade].call(cascade_results) if @config[:on_cascade].respond_to?(:call)
        rescue StandardError => e
          # Log callback error but don't fail the cascade
          BreakerMachines.logger&.error "Cascade callback error: #{e.message}"
        end
      end

      cascade_results
    end

    def trigger_emergency_protocol(affected_circuits)
      BreakerMachines.instrument('emergency_protocol_triggered', {
                                   protocol: @emergency_protocol,
                                   source_circuit: @name,
                                   affected_circuits: affected_circuits
                                 })

      # Allow custom emergency protocol handling
      owner = @config[:owner]
      if owner&.respond_to?(@emergency_protocol, true)
        begin
          owner.send(@emergency_protocol, affected_circuits)
        rescue StandardError => e
          BreakerMachines.logger&.error "Emergency protocol error: #{e.message}"
        end
      elsif respond_to?(@emergency_protocol, true)
        begin
          send(@emergency_protocol, affected_circuits)
        rescue StandardError => e
          BreakerMachines.logger&.error "Emergency protocol error: #{e.message}"
        end
      end
    end

    # Override the on_circuit_open callback to include cascading
    def on_circuit_open
      super # Call the original implementation
      perform_cascade if @dependent_circuits.any?
    end

    # Force open should also cascade
    def force_open!
      result = super
      perform_cascade if result && @dependent_circuits.any?
      result
    end
  end
end
