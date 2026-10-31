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
      @named_last_used = Concurrent::Map.new # Monotonic time each was last handed out
      @mutex = Mutex.new
      @registration_count = 0
      @cleanup_interval = 100 # Clean up every N registrations
    end

    # Register a circuit instance
    def register(circuit)
      @mutex.synchronize do
        @circuits[circuit.object_id] = WeakRef.new(circuit)

        # Periodic cleanup
        @registration_count += 1
        if @registration_count >= @cleanup_interval
          cleanup_dead_references_unsafe
          cleanup_stale_dynamic_circuits_unsafe(DYNAMIC_CIRCUIT_MAX_AGE)
          @registration_count = 0
        end
      end
    end

    # Unregister a circuit instance
    def unregister(circuit)
      @mutex.synchronize do
        @circuits.delete(circuit.object_id)
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
    def force_open(name)
      circuits = find_by_name(name)
      return false if circuits.empty?

      circuits.each(&:force_open)
      true
    end

    # Force close a circuit by name
    def force_close(name)
      circuits = find_by_name(name)
      return false if circuits.empty?

      circuits.each(&:force_close)
      true
    end

    # Reset a circuit by name
    def reset(name)
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
        circuits: circuits.map { |c| c.stats.to_h },
        health: {
          open_count: circuits.count(&:open?),
          closed_count: circuits.count(&:closed?),
          half_open_count: circuits.count(&:half_open?),
          total_failures: circuits.sum { |c| c.stats.failure_count },
          total_successes: circuits.sum { |c| c.stats.success_count }
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
        existing = @named_circuits[name]
        if existing
          @named_last_used[name] = BreakerMachines.monotonic_time
          return existing
        end

        # Create new circuit with weak owner reference
        # Don't auto-register to avoid deadlock
        weak_owner = owner.is_a?(WeakRef) ? owner : WeakRef.new(owner)
        circuit_config = config.merge(owner: weak_owner, auto_register: false)
        new_circuit = Circuit.new(name, circuit_config)

        @circuits[new_circuit.object_id] = WeakRef.new(new_circuit)
        @named_circuits[name] = new_circuit
        @named_last_used[name] = BreakerMachines.monotonic_time

        new_circuit
      end
    end

    # Remove a dynamic circuit by name
    def remove_dynamic_circuit(name)
      @mutex.synchronize do
        if @named_circuits.key?(name)
          circuit = @named_circuits.delete(name)
          @named_last_used.delete(name)
          @circuits.delete(circuit.object_id) if circuit
          true
        else
          false
        end
      end
    end

    # Get all dynamic circuit names
    def dynamic_circuit_names
      @mutex.synchronize do
        @named_circuits.keys
      end
    end

    # Cleanup stale dynamic circuits older than given age
    def cleanup_stale_dynamic_circuits(max_age_seconds = DYNAMIC_CIRCUIT_MAX_AGE)
      @mutex.synchronize { cleanup_stale_dynamic_circuits_unsafe(max_age_seconds) }
    end

    # Seconds a named dynamic circuit is kept after its last activity.
    DYNAMIC_CIRCUIT_MAX_AGE = 3600

    private def cleanup_stale_dynamic_circuits_unsafe(max_age_seconds)
      cutoff_time = BreakerMachines.monotonic_time - max_age_seconds
      stale_names = []

      @named_circuits.each_pair do |name, _circuit|
        last_used = @named_last_used[name]
        stale_names << name if last_used.nil? || last_used < cutoff_time
      end

      stale_names.each do |name|
        circuit = @named_circuits.delete(name)
        @named_last_used.delete(name)
        @circuits.delete(circuit.object_id) if circuit
      end

      stale_names.size
    end

    # Clear all circuits (useful for testing)
    def clear
      @mutex.synchronize do
        @circuits.clear
        @named_circuits.clear
        @named_last_used.clear
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
