# frozen_string_literal: true

require 'singleton'
require 'weakref'

module BreakerMachines
  # Global registry for tracking all circuit breaker instances
  class Registry
    include Singleton

    def initialize
      @circuits = Concurrent::Map.new
      @named_circuits = Concurrent::Map.new # For dynamic circuits by name
      @mutex = Mutex.new
      @registration_count = 0
      @cleanup_interval = 100 # Clean up every N registrations
    end

    # Register a circuit instance
    def register(circuit)
      @mutex.synchronize do
        # Use circuit object as key - Concurrent::Map handles object identity correctly
        @circuits[circuit] = WeakRef.new(circuit)

        # Periodic cleanup
        @registration_count += 1
        if @registration_count >= @cleanup_interval
          cleanup_dead_references_unsafe
          @registration_count = 0
        end
      end
    end

    # Unregister a circuit instance
    def unregister(circuit)
      @mutex.synchronize do
        @circuits.delete(circuit)
      end
    end

    # Get all active circuits
    def all_circuits
      @mutex.synchronize do
        @circuits.values.map do |weak_ref|
          weak_ref.__getobj__
        rescue WeakRef::RefError
          nil
        end.compact
      end
    end

    # Find circuits by name
    def find_by_name(name)
      all_circuits.select { |circuit| circuit.name == name }
    end

    # Find first circuit by name
    def find(name)
      find_by_name(name).first
    end

    # Force open a circuit by name
    def force_open(name) # rubocop:disable Naming/PredicateMethod
      circuits = find_by_name(name)
      return false if circuits.empty?

      circuits.each(&:force_open)
      true
    end

    # Force close a circuit by name
    def force_close(name) # rubocop:disable Naming/PredicateMethod
      circuits = find_by_name(name)
      return false if circuits.empty?

      circuits.each(&:force_close)
      true
    end

    # Reset a circuit by name
    def reset(name) # rubocop:disable Naming/PredicateMethod
      circuits = find_by_name(name)
      return false if circuits.empty?

      circuits.each(&:reset)
      true
    end

    # Get summary statistics
    def stats_summary
      circuits = all_circuits
      {
        total: circuits.size,
        by_state: circuits.group_by(&:status_name).transform_values(&:count),
        by_name: circuits.group_by(&:name).transform_values(&:count)
      }
    end

    # Get all stats with detailed metrics
    def all_stats
      circuits = all_circuits

      {
        summary: stats_summary,
        circuits: circuits.map(&:stats),
        health: {
          open_count: circuits.count(&:open?),
          closed_count: circuits.count(&:closed?),
          half_open_count: circuits.count(&:half_open?),
          total_failures: circuits.sum { |c| c.stats[:failure_count] },
          total_successes: circuits.sum { |c| c.stats[:success_count] }
        }
      }
    end

    # Get detailed information for all circuits
    def detailed_report
      all_circuits.map(&:to_h)
    end

    # Get or create a globally managed dynamic circuit
    def get_or_create_dynamic_circuit(name, owner, config)
      @mutex.synchronize do
        # Check if circuit already exists and is still alive
        if @named_circuits.key?(name)
          weak_ref = @named_circuits[name]
          begin
            existing_circuit = weak_ref.__getobj__
            return existing_circuit if existing_circuit
          rescue WeakRef::RefError
            # Circuit was garbage collected, remove the stale reference
            @named_circuits.delete(name)
          end
        end

        # Create new circuit with weak owner reference
        # Don't auto-register to avoid deadlock
        weak_owner = owner.is_a?(WeakRef) ? owner : WeakRef.new(owner)
        circuit_config = config.merge(owner: weak_owner, auto_register: false)
        new_circuit = Circuit.new(name, circuit_config)

        # Manually register the circuit (we're already in sync block)
        @circuits[new_circuit] = WeakRef.new(new_circuit)
        @named_circuits[name] = WeakRef.new(new_circuit)

        new_circuit
      end
    end

    # Remove a dynamic circuit by name
    def remove_dynamic_circuit(name)
      @mutex.synchronize do
        if @named_circuits.key?(name)
          weak_ref = @named_circuits.delete(name)
          begin
            circuit = weak_ref.__getobj__
            @circuits.delete(circuit) if circuit
            true
          rescue WeakRef::RefError
            false
          end
        else
          false
        end
      end
    end

    # Get all dynamic circuit names
    def dynamic_circuit_names
      @mutex.synchronize do
        alive_names = []
        @named_circuits.each_pair do |name, weak_ref|
          weak_ref.__getobj__
          alive_names << name
        rescue WeakRef::RefError
          @named_circuits.delete(name)
        end
        alive_names
      end
    end

    # Cleanup stale dynamic circuits older than given age
    def cleanup_stale_dynamic_circuits(max_age_seconds = 3600)
      @mutex.synchronize do
        cutoff_time = Time.now - max_age_seconds
        stale_names = []

        @named_circuits.each_pair do |name, weak_ref|
          circuit = weak_ref.__getobj__
          # Check if circuit has a last_activity_time and it's stale
          if circuit.respond_to?(:last_activity_time) &&
             circuit.last_activity_time &&
             circuit.last_activity_time < cutoff_time
            stale_names << name
          end
        rescue WeakRef::RefError
          stale_names << name
        end

        stale_names.each do |name|
          weak_ref = @named_circuits.delete(name)
          begin
            circuit = weak_ref.__getobj__
            @circuits.delete(circuit) if circuit
          rescue WeakRef::RefError
            # Already gone
          end
        end

        stale_names.size
      end
    end

    # Clear all circuits (useful for testing)
    def clear
      @mutex.synchronize do
        @circuits.clear
        @named_circuits.clear
      end
    end

    # Clean up dead references (thread-safe)
    def cleanup_dead_references
      @mutex.synchronize do
        cleanup_dead_references_unsafe
      end
    end

    private

    # Clean up dead references (must be called within mutex)
    def cleanup_dead_references_unsafe
      dead_ids = []
      @circuits.each_pair do |id, weak_ref|
        weak_ref.__getobj__
      rescue WeakRef::RefError
        dead_ids << id
      end

      dead_ids.each { |id| @circuits.delete(id) }
    end
  end
end
