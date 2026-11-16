# frozen_string_literal: true

require 'weakref'

module BreakerMachines
  # Circuit definitions on a class, built per instance.
  #
  #   class WeatherService
  #     include BreakerMachines::DSL
  #
  #     circuit :api do
  #       policy WEATHER_POLICY
  #       handle Net::ReadTimeout
  #       fallback { |error| cached_forecast }
  #     end
  #
  #     def forecast = circuit(:api).call { fetch }
  #   end
  #
  # A definition needs a Policy; the rest are the circuit's runtime keywords.
  # Hooks and fallbacks run `instance_exec`'d on the instance. Definitions
  # and templates are inherited and may be overridden.
  module DSL
    # Collects one definition: a Policy, the circuit class and its runtime
    # keywords.
    class CircuitBuilder
      def initialize(base = {})
        @config = base.dup
      end

      # The definition: `{ policy:, circuit_class:, **runtime }`.
      # ArgumentError without a policy.
      def config
        raise ArgumentError, 'a circuit definition needs a policy' unless @config.key?(:policy)

        @config.dup.freeze
      end

      def policy(policy) = @config[:policy] = policy

      # The errors that count as failures.
      def handle(*exceptions) = @config[:exceptions] = exceptions

      # Add a fallback; several are tried in the order added.
      def fallback(value = nil, &block)
        raise ArgumentError, 'fallback needs a value or a block' if value.nil? && block.nil?

        @config[:fallback] = [*@config[:fallback], block || value]
      end

      # Race these fallbacks; the first that returns wins.
      def parallel_fallback(fallbacks) = @config[:fallback] = ParallelFallback.new(fallbacks)

      def on_open(&block) = @config[:on_open] = block
      def on_close(&block) = @config[:on_close] = block
      def on_half_open(&block) = @config[:on_half_open] = block
      def on_reject(&block) = @config[:on_reject] = block

      def storage(backend) = @config[:storage] = backend

      # Integer nanoseconds a call may take.
      def timeout(nanoseconds) = @config[:timeout] = nanoseconds

      def fiber_safe(enabled = true) = @config[:fiber_safe] = enabled

      # Send the call again after each `delay` (Integer ns), up to
      # `max_requests` in flight; first success wins.
      def hedged(delay: 0, max_requests: 2) = @config[:hedged] = { delay:, max_requests: }

      # Callables tried as hedges (with `hedged`) or in turn.
      def backends(*callables) = @config[:backends] = callables.flatten

      # Refuse calls while any of these circuits is open (a CoordinatedCircuit).
      def depends_on(*circuits)
        @config[:circuit_class] ||= CoordinatedCircuit
        @config[:depends_on] = circuits.flatten
      end

      # Force these circuits open whenever this one opens (a CascadingCircuit).
      def cascades_to(*circuits)
        @config[:circuit_class] = CascadingCircuit
        @config[:cascades_to] = circuits.flatten
      end

      def emergency_protocol(name) = @config[:emergency_protocol] = name

      def on_cascade(&block) = @config[:on_cascade] = block
    end

    def self.included(base)
      super
      base.extend(ClassMethods)
    end

    # Class-level definitions.
    module ClassMethods
      # Define (with a block) or read the definition `name`.
      def circuit(name, &)
        own_circuits[name] = build(&) if block_given?
        circuits[name]
      end

      # Define a CascadingCircuit; `cascades_to` inside the block names its
      # dependents.
      def cascade_circuit(name, &)
        own_circuits[name] = build({ circuit_class: CascadingCircuit }, &)
        circuits[name]
      end

      # Every definition, inherited ones included.
      def circuits
        inherited = superclass.respond_to?(:circuits) ? superclass.circuits : {}
        inherited.merge(own_circuits)
      end

      # Define (with a block) or read the template `name`.
      def circuit_template(name, &)
        own_templates[name] = build(&) if block_given?
        circuit_templates[name]
      end

      # Every template, inherited ones included.
      def circuit_templates
        inherited = superclass.respond_to?(:circuit_templates) ? superclass.circuit_templates : {}
        inherited.merge(own_templates)
      end

      private

      def own_circuits = (@own_circuits ||= {})
      def own_templates = (@own_templates ||= {})
      def build(base = {}, &) = CircuitBuilder.new(base).tap { |builder| builder.instance_eval(&) }.config
    end

    # This instance's circuit for the definition `name`. KeyError for an
    # unknown name.
    def circuit(name)
      circuit_instances[name] ||= build_circuit(name, self.class.circuits.fetch(name))
    end

    # A circuit defined inline, from `template` and the block. With
    # `global: true` it is the registry's shared circuit of that name.
    def dynamic_circuit(name, template: nil, global: false, &block)
      base = template ? self.class.circuit_templates.fetch(template) : {}
      definition = block ? CircuitBuilder.new(base).tap { |b| b.instance_eval(&block) }.config : base
      if global
        policy, circuit_class, runtime = split(definition)
        BreakerMachines.registry.get_or_create_dynamic_circuit(name, self, policy, circuit_class:, **runtime)
      else
        circuit_instances[name] ||= build_circuit(name, definition)
      end
    end

    def circuit_instances = (@circuit_instances ||= {})

    def reset_all_circuits = circuit_instances.each_value(&:reset)

    # Each circuit's one-line summary.
    def circuits_summary = circuit_instances.transform_values(&:summary)

    private

    def build_circuit(name, definition)
      policy, circuit_class, runtime = split(definition)
      circuit_class.new(name, policy, **runtime, owner: self)
    end

    def split(definition)
      definition = definition.dup
      policy = definition.delete(:policy) { raise ArgumentError, 'a circuit definition needs a policy' }
      [policy, definition.delete(:circuit_class) || Circuit, definition]
    end
  end
end
