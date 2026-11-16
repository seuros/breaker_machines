# frozen_string_literal: true

require 'singleton'
require 'weakref'

module BreakerMachines
  # Every live circuit, held weakly, and the named dynamic circuits shared by
  # their owners, held strongly until removed or stale.
  class Registry
    include Singleton

    # Nanoseconds a named dynamic circuit is kept after it was last handed out.
    DYNAMIC_CIRCUIT_MAX_AGE = 3_600 * 1_000_000_000

    # Registrations between sweeps of dead references and stale dynamic
    # circuits.
    CLEANUP_INTERVAL = 100

    def initialize
      @circuits = {}
      @named = {}
      @last_used = {}
      @mutex = Mutex.new
      @registrations = 0
    end

    def register(circuit)
      @mutex.synchronize do
        @circuits[circuit.object_id] = WeakRef.new(circuit)
        @registrations += 1
        next unless @registrations >= CLEANUP_INTERVAL

        sweep_dead
        sweep_stale(DYNAMIC_CIRCUIT_MAX_AGE)
        @registrations = 0
      end
      circuit
    end

    def unregister(circuit)
      @mutex.synchronize { @circuits.delete(circuit.object_id) }
      nil
    end

    def all_circuits
      @mutex.synchronize { live }
    end

    def find_by_name(name) = all_circuits.select { |circuit| circuit.name == name }

    def find(name) = find_by_name(name).first

    # Force every circuit named `name` open; false when there is none.
    def force_open(name) = each_named(name, &:force_open)

    # Force every circuit named `name` closed; false when there is none.
    def force_close(name) = each_named(name, &:force_close)

    # Reset every circuit named `name`; false when there is none.
    def reset(name) = each_named(name, &:reset)

    def stats_summary
      circuits = all_circuits
      {
        total: circuits.size,
        by_state: circuits.group_by(&:state).transform_values(&:count),
        by_name: circuits.group_by(&:name).transform_values(&:count)
      }
    end

    def detailed_report = all_circuits.map(&:to_h)

    # The dynamic circuit named `name`, built as `circuit_class` from
    # `policy` and `runtime` the first time and shared afterwards. `owner` is
    # held weakly.
    def get_or_create_dynamic_circuit(name, owner, policy, circuit_class: Circuit, **runtime)
      @mutex.synchronize do
        @last_used[name] = BreakerMachines.monotonic_time
        @named[name] ||= begin
          circuit = circuit_class.new(name, policy, **runtime, owner:, auto_register: false)
          @circuits[circuit.object_id] = WeakRef.new(circuit)
          circuit
        end
      end
    end

    def remove_dynamic_circuit(name)
      @mutex.synchronize do
        circuit = @named.delete(name)
        @last_used.delete(name)
        @circuits.delete(circuit.object_id) if circuit
        !circuit.nil?
      end
    end

    def dynamic_circuit_names = @mutex.synchronize { @named.keys }

    # Drop dynamic circuits not handed out for `max_age` nanoseconds; answers
    # how many were dropped.
    def cleanup_stale_dynamic_circuits(max_age = DYNAMIC_CIRCUIT_MAX_AGE)
      @mutex.synchronize { sweep_stale(max_age) }
    end

    def cleanup_dead_references
      @mutex.synchronize { sweep_dead }
    end

    def clear
      @mutex.synchronize do
        @circuits.clear
        @named.clear
        @last_used.clear
      end
      nil
    end

    private

    def each_named(name, &)
      circuits = find_by_name(name)
      circuits.each(&)
      !circuits.empty?
    end

    def live
      @circuits.values.filter_map do |ref|
        ref.__getobj__
      rescue WeakRef::RefError
        nil
      end
    end

    def sweep_dead
      dead = @circuits.select do |_, ref|
        ref.__getobj__
        false
      rescue WeakRef::RefError
        true
      end
      dead.each_key { |id| @circuits.delete(id) }
      dead.size
    end

    def sweep_stale(max_age)
      cutoff = BreakerMachines.monotonic_time - max_age
      stale = @named.keys.select { |name| @last_used.fetch(name, cutoff - 1) < cutoff }
      stale.each do |name|
        circuit = @named.delete(name)
        @last_used.delete(name)
        @circuits.delete(circuit.object_id)
      end
      stale.size
    end
  end
end
