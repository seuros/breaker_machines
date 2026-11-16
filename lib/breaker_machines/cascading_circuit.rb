# frozen_string_literal: true

module BreakerMachines
  # Cascade information for introspection.
  CascadeInfo = Data.define(:dependent_circuits, :emergency_protocol, :cascade_triggered_at, :dependent_status)
  # Sealed like the core values: no subclass, no bare `allocate`.
  CascadeInfo.singleton_class.undef_method(:allocate)
  CascadeInfo.define_singleton_method(:inherited) { |_| raise TypeError, "#{CascadeInfo} cannot be subclassed" }

  # A CoordinatedCircuit that, whenever it opens, forces open the circuits
  # that depend on it, as a failed subspace relay takes the weapons and
  # sensors down with it.
  #
  # Runtime keywords: `cascades_to:` circuits or names; `emergency_protocol:`
  # a method name called on the owner (or this circuit) with the circuits
  # tripped; `on_cascade:` a hook called with them.
  class CascadingCircuit < CoordinatedCircuit
    attr_reader :dependent_circuits, :emergency_protocol, :cascade_triggered_at

    def initialize(name, policy, cascades_to: [], emergency_protocol: nil, on_cascade: nil, **runtime)
      @dependent_circuits = Array(cascades_to).freeze
      @emergency_protocol = emergency_protocol
      @on_cascade = on_cascade
      @cascade_triggered_at = nil
      super(name, policy, **runtime)
    end

    # Force every closed or half-open dependent open now; answers their names.
    def cascade_failure! = perform_cascade

    # Each dependent's state, or :not_found.
    def dependent_status
      @dependent_circuits.to_h do |dependency|
        [dependency_name(dependency), find_dependent_circuit(dependency)&.state || :not_found]
      end
    end

    def dependents_compromised? = dependent_status.value?(:open)

    def cascade_info
      CascadeInfo.new(dependent_circuits: @dependent_circuits.map { dependency_name(it) },
                      emergency_protocol: @emergency_protocol, cascade_triggered_at: @cascade_triggered_at,
                      dependent_status:)
    end

    def summary
      return super if @dependent_circuits.empty?

      tripped = dependent_status.values.count(:open)
      tail = @cascade_triggered_at ? " CASCADE: #{tripped}/#{@dependent_circuits.size} dependents open." : ''
      "#{super}#{tail}"
    end

    private

    # Runs after the lock is released, like every hook.
    def announce(state)
      super
      perform_cascade if state == :open && !@dependent_circuits.empty?
    end

    def perform_cascade
      @cascade_triggered_at = now
      tripped = @dependent_circuits.filter_map do |dependency|
        circuit = find_dependent_circuit(dependency)
        next unless circuit && !circuit.open?

        circuit.force_open
        BreakerMachines.instrument('cascade_failure', source_circuit: name, target_circuit: circuit.name,
                                                      emergency_protocol: @emergency_protocol)
        circuit.name
      end
      trigger_emergency_protocol(tripped) unless tripped.empty?
      tripped
    end

    def trigger_emergency_protocol(tripped)
      if @emergency_protocol
        BreakerMachines.instrument('emergency_protocol_triggered', protocol: @emergency_protocol,
                                                                   source_circuit: name, affected_circuits: tripped)
        target = [resolve_owner, self].find { it.respond_to?(@emergency_protocol, true) }
        target&.__send__(@emergency_protocol, tripped)
      end
      @on_cascade&.call(tripped)
    rescue StandardError => e
      BreakerMachines.instrument('callback_error', circuit: name, callback: :cascade, error: e)
    end
  end
end
