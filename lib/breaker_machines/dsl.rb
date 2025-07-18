# frozen_string_literal: true

module BreakerMachines
  # DSL module for adding circuit breakers to classes
  #
  # This module uses WeakRef to track instances that include the DSL.
  # Why? In long-running applications (web servers, background workers),
  # objects that include this DSL may be created and destroyed frequently.
  # Without WeakRef, the registry would hold strong references to these
  # objects, preventing garbage collection and causing memory leaks.
  #
  # Example scenario: A Rails controller that includes BreakerMachines::DSL
  # is instantiated for each request. Without WeakRef, every controller
  # instance would be kept in memory forever.
  module DSL
    extend ActiveSupport::Concern

    # Track instances for each class that includes DSL
    # Using WeakRef to allow garbage collection
    @instance_registries = Concurrent::Map.new

    class_methods do
      # Get or create instance registry for this class
      def instance_registry
        # Access the module-level registry
        registry = BreakerMachines::DSL.instance_variable_get(:@instance_registries)
        registry.compute_if_absent(self) { Concurrent::Array.new }
      end

      # Clean up dead references in the registry
      def cleanup_instance_registry
        registry = instance_registry
        # Concurrent::Array supports delete_if
        registry.delete_if do |weak_ref|
          weak_ref.__getobj__
          false
        rescue WeakRef::RefError
          true
        end
      end

      def circuit(name, &block)
        @circuits ||= {}

        if block_given?
          builder = DSL::CircuitBuilder.new
          builder.instance_eval(&block)
          @circuits[name] = builder.config
        end

        @circuits[name]
      end

      # Define a cascading circuit breaker that can trip dependent circuits
      def cascade_circuit(name, &block)
        @circuits ||= {}

        if block_given?
          builder = DSL::CascadingCircuitBuilder.new
          builder.instance_eval(&block)
          @circuits[name] = builder.config.merge(circuit_type: :cascading)
        end

        @circuits[name]
      end

      def circuits
        # Start with parent circuits if available
        base_circuits = if superclass.respond_to?(:circuits)
                          superclass.circuits.deep_dup
                        else
                          {}
                        end

        # Merge with our own circuits
        if @circuits
          base_circuits.merge(@circuits)
        else
          base_circuits
        end
      end

      # Define reusable circuit templates
      def circuit_template(name, &block)
        @circuit_templates ||= {}

        if block_given?
          builder = DSL::CircuitBuilder.new
          builder.instance_eval(&block)
          @circuit_templates[name] = builder.config
        end

        @circuit_templates[name]
      end

      # Get all circuit templates
      def circuit_templates
        # Start with parent templates if available
        base_templates = if superclass.respond_to?(:circuit_templates)
                           superclass.circuit_templates.deep_dup
                         else
                           {}
                         end

        # Merge with our own templates
        if @circuit_templates
          base_templates.merge(@circuit_templates)
        else
          base_templates
        end
      end

      # Get circuit definitions without sensitive data
      def circuit_definitions
        circuits.transform_values { |config| config.except(:owner, :storage, :metrics) }
      end

      # Reset all circuits for all instances of this class
      def reset_all_circuits
        cleanup_instance_registry # Clean up dead refs first

        instance_registry.each do |weak_ref|
          instance = weak_ref.__getobj__
          circuit_instances = instance.instance_variable_get(:@circuit_instances)
          circuit_instances&.each_value(&:force_close!)
        rescue WeakRef::RefError
          # Instance was garbage collected, skip it
        end
      end

      # Get aggregated stats for all circuits of this class
      def circuit_stats
        stats = Hash.new { |h, k| h[k] = { total: 0, by_state: {} } }
        cleanup_instance_registry # Clean up dead refs first

        instance_registry.each do |weak_ref|
          instance = weak_ref.__getobj__
          circuit_instances = instance.instance_variable_get(:@circuit_instances)
          next unless circuit_instances

          circuit_instances.each do |name, circuit|
            stats[name][:total] += 1
            state = circuit.status_name
            stats[name][:by_state][state] ||= 0
            stats[name][:by_state][state] += 1
          end
        rescue WeakRef::RefError
          # Instance was garbage collected, skip it
        end

        stats
      end
    end

    # Use included callback to add instance tracking
    def self.included(base)
      super

      # Hook into new to register instances
      base.singleton_class.prepend(Module.new do
        def new(...)
          instance = super
          instance_registry << WeakRef.new(instance)
          instance
        end
      end)
    end

    def circuit(name)
      self.class.circuits[name] ||= {}
      @circuit_instances ||= {}

      config = self.class.circuits[name].merge(owner: self)
      circuit_type = config.delete(:circuit_type)

      @circuit_instances[name] ||= case circuit_type
                                   when :cascading
                                     CascadingCircuit.new(name, config)
                                   else
                                     Circuit.new(name, config)
                                   end
    end

    # Create a dynamic circuit breaker with inline configuration
    # Options:
    #   global: true - Store circuit globally, preventing memory leaks in long-lived objects
    #   global: false - Store circuit locally in this instance (default, backward compatible)
    def dynamic_circuit(name, template: nil, global: false, &config_block)
      # Start with template config if provided
      base_config = if template && self.class.circuit_templates[template]
                      self.class.circuit_templates[template].deep_dup
                    else
                      default_circuit_config
                    end

      # Apply additional configuration if block provided
      if config_block
        builder = DSL::CircuitBuilder.new
        builder.instance_variable_set(:@config, base_config.deep_dup)
        builder.instance_eval(&config_block)
        base_config = builder.config
      end

      if global
        # Use global registry to prevent memory leaks
        BreakerMachines.registry.get_or_create_dynamic_circuit(name, self, base_config)
      else
        # Local storage (backward compatible)
        @circuit_instances ||= {}
        @circuit_instances[name] ||= Circuit.new(name, base_config.merge(owner: self))
      end
    end

    # Apply a template to an existing or new circuit
    def apply_template(circuit_name, template_name)
      template_config = self.class.circuit_templates[template_name]
      raise ArgumentError, "Template '#{template_name}' not found" unless template_config

      @circuit_instances ||= {}
      @circuit_instances[circuit_name] = Circuit.new(circuit_name, template_config.merge(owner: self))
    end

    private

    def default_circuit_config
      {
        failure_threshold: 5,
        failure_window: 60,
        success_threshold: 1,
        timeout: nil,
        reset_timeout: 60,
        half_open_calls: 1,
        exceptions: [StandardError],
        storage: nil,
        metrics: nil,
        fallback: nil,
        on_open: nil,
        on_close: nil,
        on_half_open: nil,
        on_reject: nil,
        notifications: [],
        fiber_safe: BreakerMachines.config.fiber_safe
      }
    end

    public

    # Get all circuit instances for this object
    def circuit_instances
      @circuit_instances || {}
    end

    # Get summary of all circuits for this instance
    def circuits_summary
      circuit_instances.transform_values(&:summary)
    end

    # Get detailed information for all circuits
    def circuits_report
      circuit_instances.transform_values(&:to_h)
    end

    # Reset all circuits for this instance
    def reset_all_circuits
      circuit_instances.each_value(&:force_close!)
    end

    # Remove a global dynamic circuit by name
    def remove_dynamic_circuit(name)
      BreakerMachines.registry.remove_dynamic_circuit(name)
    end

    # Get all dynamic circuit names from global registry
    def dynamic_circuit_names
      BreakerMachines.registry.dynamic_circuit_names
    end

    # Cleanup stale dynamic circuits (global)
    def cleanup_stale_dynamic_circuits(max_age_seconds = 3600)
      BreakerMachines.registry.cleanup_stale_dynamic_circuits(max_age_seconds)
    end
  end
end
