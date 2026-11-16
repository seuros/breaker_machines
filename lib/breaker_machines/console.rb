# frozen_string_literal: true

module BreakerMachines
  # A line-oriented console over the registry. Commands: list, stats,
  # show NAME, events NAME [LIMIT], open NAME, close NAME, reset NAME,
  # report, cleanup, help, exit.
  class Console
    COMMANDS = %w[list stats show events open close reset report cleanup help exit].freeze

    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
    end

    def run
      @output.puts 'BreakerMachines console. Type help for commands.'
      loop do
        @output.print 'breaker> '
        line = @input.gets
        break unless line && process(line.strip) != :exit
      end
      nil
    end

    # Run one command line; answers :exit for exit.
    def process(line)
      command, name, limit = line.split
      case command
      when nil then nil
      when 'list' then list
      when 'stats' then puts_hash(BreakerMachines.registry.stats_summary)
      when 'show' then with_circuit(name) { |circuit| puts_hash(circuit.to_h) }
      when 'events' then with_circuit(name) { |circuit| events(circuit, Integer(limit || 10)) }
      when 'open' then act(name, :force_open)
      when 'close' then act(name, :force_close)
      when 'reset' then act(name, :reset)
      when 'report' then BreakerMachines.registry.all_circuits.each { @output.puts it.summary }
      when 'cleanup' then @output.puts "Removed #{BreakerMachines.registry.cleanup_dead_references} dead references"
      when 'help' then @output.puts "Commands: #{COMMANDS.join(', ')}"
      when 'exit', 'quit' then :exit
      else @output.puts "Unknown command: #{command}"
      end
    end

    private

    def list
      circuits = BreakerMachines.registry.all_circuits
      @output.puts 'No circuits registered' if circuits.empty?
      circuits.each { |circuit| @output.puts "#{circuit.name}\t#{circuit.state}" }
    end

    def events(circuit, limit)
      circuit.events(limit).each do |event|
        @output.puts "#{event.at}\t#{event.outcome}\t#{event.took}ns"
      end
    end

    def act(name, action)
      if BreakerMachines.registry.public_send(action, coerce(name))
        @output.puts "#{action} #{name}"
      else
        @output.puts "Circuit not found: #{name}"
      end
    end

    def with_circuit(name)
      circuit = BreakerMachines.registry.find(coerce(name))
      return @output.puts("Circuit not found: #{name}") unless circuit

      yield circuit
    end

    # Circuits are often named by Symbols; the console reads Strings.
    def coerce(name)
      registry = BreakerMachines.registry
      registry.find(name) ? name : name&.to_sym
    end

    def puts_hash(hash) = hash.each { |key, value| @output.puts "#{key}: #{value.inspect}" }
  end
end
