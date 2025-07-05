# frozen_string_literal: true

require 'singleton'
require 'weakref'

module BreakerMachines
  # Global registry for tracking all circuit breaker instances
  class Registry
    include Singleton

    def initialize
      @circuits = Concurrent::Map.new
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

    # Get summary statistics
    def stats_summary
      circuits = all_circuits
      {
        total: circuits.size,
        by_state: circuits.group_by(&:status_name).transform_values(&:count),
        by_name: circuits.group_by(&:name).transform_values(&:count)
      }
    end

    # Get detailed information for all circuits
    def detailed_report
      all_circuits.map(&:to_h)
    end

    # Clear all circuits (useful for testing)
    def clear
      @mutex.synchronize do
        @circuits.clear
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
