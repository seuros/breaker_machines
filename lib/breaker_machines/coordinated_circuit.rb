# frozen_string_literal: true

module BreakerMachines
  # A Circuit that refuses calls while a circuit it depends on is open.
  # The check is the runtime's, made before the core is asked, so it changes
  # nothing: a refused call raises CircuitDependencyError (refusal
  # `:dependency`) unless a fallback replaces it. The lifecycle still moves
  # only on the core's answers.
  #
  # `depends_on:` circuits or names, resolved through the registry and then
  # through the owner's `circuit(name)`.
  class CoordinatedCircuit < Circuit
    attr_reader :dependencies

    def initialize(name, policy, depends_on: [], **runtime)
      @dependencies = Array(depends_on).freeze
      super(name, policy, **runtime)
    end

    def call(&)
      down = dependencies_down
      return super if down.empty?

      run_hook(:on_reject)
      error = CircuitDependencyError.new(name, down)
      raise error unless @fallback

      run_fallback(error)
    end

    # Whether every dependency is closed or half-open (a missing one counts
    # as healthy).
    def dependencies_healthy? = dependencies_down.empty?

    private

    def dependencies_down
      @dependencies.filter_map do |dependency|
        circuit = find_dependent_circuit(dependency)
        dependency_name(dependency) if circuit&.open?
      end
    end

    def dependency_name(dependency) = dependency.is_a?(Circuit) ? dependency.name : dependency

    def find_dependent_circuit(dependency)
      return dependency if dependency.is_a?(Circuit)

      found = BreakerMachines.registry.find(dependency)
      return found if found

      owner = resolve_owner
      owner.circuit(dependency) if owner.respond_to?(:circuit)
    rescue KeyError
      nil
    end
  end
end
