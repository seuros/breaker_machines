# frozen_string_literal: true

module BreakerMachines
  # CircuitGroup provides coordinated management of multiple related circuits
  # with support for dependencies, shared configuration, and group-wide operations
  class CircuitGroup
    include BreakerMachines::DSL

    attr_reader :name, :circuits, :dependencies, :config

    def initialize(name, config = {})
      @name = name
      @config = config
      @circuits = {}
      @dependencies = {}
      @async_mode = config[:async_mode] || false
    end

    # Define a circuit within this group with optional dependencies
    # @param name [Symbol] Circuit name
    # @param options [Hash] Circuit configuration
    # @option options [Symbol, Array<Symbol>] :depends_on Other circuits this one depends on
    # @option options [Proc] :guard_with Additional guard conditions
    def circuit(name, options = {}, &)
      depends_on = Array(options.delete(:depends_on))
      guard_proc = options.delete(:guard_with)

      # Add group-wide defaults
      circuit_config = @config.merge(options)

      # Create appropriate circuit type
      circuit_class = if options[:cascades_to] || depends_on.any?
                        BreakerMachines::CascadingCircuit
                      elsif @async_mode
                        BreakerMachines::AsyncCircuit
                      else
                        BreakerMachines::Circuit
                      end

      # Build the circuit
      circuit_instance = if block_given?
                           builder = BreakerMachines::DSL::CircuitBuilder.new
                           builder.instance_eval(&)
                           built_config = builder.config.merge(circuit_config)
                           circuit_class.new(full_circuit_name(name), built_config)
                         else
                           circuit_class.new(full_circuit_name(name), circuit_config)
                         end

      # Store dependencies and guards
      if depends_on.any? || guard_proc
        @dependencies[name] = {
          depends_on: depends_on,
          guard: guard_proc
        }

        # Wrap the circuit with dependency checking
        circuit_instance = DependencyWrapper.new(circuit_instance, self, name)
      end

      @circuits[name] = circuit_instance
      BreakerMachines.register(circuit_instance)
      circuit_instance
    end

    # Get a circuit by name
    def [](name)
      @circuits[name]
    end

    # Check if all circuits in the group are healthy
    def all_healthy?
      @circuits.values.all? { |circuit| circuit.closed? || circuit.half_open? }
    end

    # Check if any circuit in the group is open
    def any_open?
      @circuits.values.any?(&:open?)
    end

    # Get status of all circuits
    def status
      @circuits.transform_values(&:status_name)
    end

    # Reset all circuits in the group
    def reset_all!
      @circuits.each_value(&:reset!)
    end

    # Force open all circuits
    def trip_all!
      @circuits.each_value(&:force_open!)
    end

    # Check dependencies for a specific circuit
    def dependencies_met?(circuit_name)
      deps = @dependencies[circuit_name]
      return true unless deps

      depends_on = deps[:depends_on]
      guard = deps[:guard]

      # Check circuit dependencies recursively
      dependencies_healthy = depends_on.all? do |dep_name|
        dep_circuit = @circuits[dep_name]
        # Circuit must exist, be healthy, AND have its own dependencies met
        dep_circuit && (dep_circuit.closed? || dep_circuit.half_open?) && dependencies_met?(dep_name)
      end

      # Check custom guard
      guard_passed = guard ? guard.call : true

      dependencies_healthy && guard_passed
    end

    private

    def full_circuit_name(name)
      "#{@name}.#{name}"
    end

    # Wrapper to enforce dependencies
    class DependencyWrapper < SimpleDelegator
      def initialize(circuit, group, name)
        super(circuit)
        @group = group
        @name = name
      end

      def call(&)
        unless @group.dependencies_met?(@name)
          raise BreakerMachines::CircuitDependencyError.new(__getobj__.name,
                                                            "Dependencies not met for circuit #{@name}")
        end

        __getobj__.call(&)
      end

      def attempt_recovery!
        return false unless @group.dependencies_met?(@name)

        __getobj__.attempt_recovery!
      end

      def reset!
        return false unless @group.dependencies_met?(@name)

        __getobj__.reset!
      end
    end
  end
end
