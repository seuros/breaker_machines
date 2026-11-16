# frozen_string_literal: true

module BreakerMachines
  # Related circuits managed together, each optionally depending on others
  # in the group: a call through a circuit whose dependencies are not all
  # closed raises CircuitDependencyError before its core is asked.
  class CircuitGroup
    attr_reader :name, :circuits

    # `runtime` keywords are passed to every circuit the group builds.
    def initialize(name, **runtime)
      @name = name
      @runtime = runtime
      @circuits = {}
      @dependencies = {}
    end

    # Build (or answer) the circuit `name` with `policy`. `depends_on:` names
    # other circuits of the group; `guard_with:` is a callable that must
    # answer truthy for calls to proceed.
    def circuit(name, policy = nil, depends_on: [], guard_with: nil, **runtime)
      return @circuits.fetch(name) unless policy

      @dependencies[name] = { depends_on: Array(depends_on), guard: guard_with }
      circuit = Circuit.new(full_circuit_name(name), policy, **@runtime, **runtime)
      @circuits[name] = GuardedCircuit.new(circuit, self, name)
    end

    def [](name) = @circuits[name]

    def all_healthy? = @circuits.values.all?(&:closed?)

    def any_open? = @circuits.values.any?(&:open?)

    def status = @circuits.transform_values(&:state)

    def reset_all! = @circuits.each_value(&:reset)

    def trip_all! = @circuits.each_value(&:force_open)

    # Whether every dependency of `name` is closed and its guard allows it.
    def dependencies_met?(name) = dependencies_down(name).empty? && guard_allows?(name)

    # The dependencies of `name` that are not closed (a missing one counts
    # as down), in the order they were declared.
    def dependencies_down(name)
      spec(name)[:depends_on].reject { |dependency| @circuits[dependency]&.closed? }
    end

    # Whether the `guard_with:` of `name` allows a call (true without one).
    def guard_allows?(name)
      guard = spec(name)[:guard]
      guard.nil? || guard.call ? true : false
    end

    private

    def full_circuit_name(name) = "#{@name}.#{name}"

    def spec(name) = @dependencies.fetch(name, { depends_on: [], guard: nil })

    # A group member: its circuit, refusing calls while its dependencies are
    # not met.
    class GuardedCircuit < SimpleDelegator
      def initialize(circuit, group, name)
        super(circuit)
        @group = group
        @member = name
      end

      # Names the dependencies that are down; none when only the guard refused.
      def call(&)
        down = @group.dependencies_down(@member)
        raise CircuitDependencyError.new(__getobj__.name, down) unless down.empty?
        raise CircuitDependencyError.new(__getobj__.name, []) unless @group.guard_allows?(@member)

        __getobj__.call(&)
      end
      alias wrap call
    end
  end
end
