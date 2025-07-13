# frozen_string_literal: true

module BreakerMachines
  # Interactive console for debugging and monitoring circuit breakers
  class Console
    def self.start
      new.run
    end

    def initialize
      @running = true
    end

    def run
      print_header
      print_help if BreakerMachines::Registry.instance.all_circuits.empty?

      while @running
        print_prompt
        command = gets&.chomp
        break unless command

        process_command(command)
      end

      puts "\nExiting BreakerMachines Console..."
    end

    private

    def print_header
      puts "\n#{'=' * 60}"
      puts "BreakerMachines Console v#{BreakerMachines::VERSION}"
      puts '=' * 60
      puts "Type 'help' for available commands"
      puts
    end

    def print_help
      puts <<~HELP
        Available commands:
          list         - List all circuits
          stats        - Show summary statistics
          show <name>  - Show details for circuits with given name
          events <name> [limit] - Show event log for circuit
          reset <name> - Reset circuit(s) to closed state
          force_open <name>  - Force circuit to open state
          force_close <name> - Force circuit to closed state
          report       - Generate full report
          cleanup      - Remove dead circuit references
          refresh      - Refresh display
          help         - Show this help
          exit/quit    - Exit console

      HELP
    end

    def print_prompt
      print '> '
    end

    def process_command(command)
      parts = command.split
      cmd = parts[0]&.downcase
      args = parts[1..]

      case cmd
      when 'help', '?'
        print_help
      when 'list', 'ls'
        list_circuits
      when 'stats'
        show_stats
      when 'show'
        show_circuit(args[0])
      when 'events'
        show_events(args[0], args[1]&.to_i || 10)
      when 'reset'
        reset_circuit(args[0])
      when 'force_open', 'open'
        force_open_circuit(args[0])
      when 'force_close', 'close'
        force_close_circuit(args[0])
      when 'report'
        generate_report
      when 'cleanup'
        cleanup_registry
      when 'refresh', 'clear'
        system('clear') || system('cls')
        print_header
      when 'exit', 'quit', 'q'
        @running = false
      else
        puts "Unknown command: #{cmd}. Type 'help' for available commands."
      end
    end

    def list_circuits
      circuits = BreakerMachines::Registry.instance.all_circuits

      if circuits.empty?
        puts 'No circuits registered.'
        return
      end

      puts "\nRegistered Circuits:"
      puts '-' * 60
      printf "%-20s %-12s %-10s %-10s %s\n", 'Name', 'State', 'Failures', 'Successes', 'Last Error'
      puts '-' * 60

      circuits.each do |circuit|
        stats = circuit.stats
        error_info = circuit.last_error ? circuit.last_error.class.name : '-'

        printf "%-20s %-12s %-10d %-10d %s\n",
               circuit.name,
               colorize_state(stats.state),
               stats.failure_count,
               stats.success_count,
               error_info
      end

      puts '-' * 60
      puts "Total: #{circuits.size} circuit(s)"
      puts
    end

    def show_stats
      stats = BreakerMachines::Registry.instance.stats_summary

      puts "\nCircuit Statistics:"
      puts '-' * 40
      puts "Total circuits: #{stats[:total]}"
      puts "\nBy State:"
      stats[:by_state].each do |state, count|
        puts "  #{colorize_state(state)}: #{count}"
      end

      puts "\nBy Name:"
      stats[:by_name].each do |name, count|
        puts "  #{name}: #{count} instance(s)"
      end
      puts
    end

    def show_circuit(name)
      if name.nil?
        puts 'Usage: show <circuit_name>'
        return
      end

      circuits = BreakerMachines::Registry.instance.find_by_name(name.to_sym)

      if circuits.empty?
        puts "No circuits found with name: #{name}"
        return
      end

      circuits.each_with_index do |circuit, index|
        puts "\n#{'-' * 60}"
        puts "Circuit ##{index + 1}: #{circuit.name}"
        puts '-' * 60

        puts circuit.summary
        puts

        stats = circuit.stats
        config = circuit.configuration

        puts "Current State: #{colorize_state(stats.state)}"
        puts "Failure Count: #{stats.failure_count} / #{config[:failure_threshold]}"
        puts "Success Count: #{stats.success_count}"

        if stats.opened_at
          puts "Opened At: #{Time.at(stats.opened_at)}"
          reset_time = Time.at(stats.opened_at + config[:reset_timeout])
          puts "Reset At: #{reset_time} (in #{(reset_time - Time.now).to_i}s)"
        end

        if circuit.last_error
          error_info = circuit.last_error_info
          puts "\nLast Error:"
          puts "  Class: #{error_info.error_class}"
          puts "  Message: #{error_info.message}"
          puts "  Time: #{Time.at(error_info.occurred_at)}"
        end

        puts "\nConfiguration:"
        puts "  Failure Threshold: #{config[:failure_threshold]}"
        puts "  Failure Window: #{config[:failure_window]}s"
        puts "  Reset Timeout: #{config[:reset_timeout]}s"
        puts "  Success Threshold: #{config[:success_threshold]}"
        puts "  Half-Open Calls: #{config[:half_open_calls]}"
      end
      puts
    end

    def show_events(name, limit)
      if name.nil?
        puts 'Usage: events <circuit_name> [limit]'
        return
      end

      circuits = BreakerMachines::Registry.instance.find_by_name(name.to_sym)

      if circuits.empty?
        puts "No circuits found with name: #{name}"
        return
      end

      circuits.each do |circuit|
        events = circuit.event_log(limit: limit)

        puts "\nEvent Log for #{circuit.name} (last #{limit} events):"
        puts '-' * 80

        if events.empty?
          puts 'No events recorded.'
        else
          printf "%-20s %-15s %-10s %-20s %s\n", 'Timestamp', 'Type', 'Duration', 'Error', 'Details'
          puts '-' * 80

          events.each do |event|
            timestamp = Time.at(event[:timestamp]).strftime('%Y-%m-%d %H:%M:%S')
            type = colorize_event_type(event[:type])
            duration = event[:duration_ms] ? "#{event[:duration_ms]}ms" : '-'
            error = event[:error_class] || '-'
            details = event[:new_state] ? "→ #{event[:new_state]}" : ''

            printf "%-20s %-15s %-10s %-20s %s\n", timestamp, type, duration, error, details
          end
        end
      end
      puts
    end

    def reset_circuit(name)
      if name.nil?
        puts 'Usage: reset <circuit_name>'
        return
      end

      circuits = BreakerMachines::Registry.instance.find_by_name(name.to_sym)

      if circuits.empty?
        puts "No circuits found with name: #{name}"
        return
      end

      circuits.each do |circuit|
        circuit.reset
        puts "Reset circuit: #{circuit.name} (now #{circuit.status_name})"
      end
    end

    def force_open_circuit(name)
      if name.nil?
        puts 'Usage: force_open <circuit_name>'
        return
      end

      circuits = BreakerMachines::Registry.instance.find_by_name(name.to_sym)

      if circuits.empty?
        puts "No circuits found with name: #{name}"
        return
      end

      circuits.each do |circuit|
        circuit.force_open
        puts "Forced open circuit: #{circuit.name} (now #{circuit.status_name})"
      end
    end

    def force_close_circuit(name)
      if name.nil?
        puts 'Usage: force_close <circuit_name>'
        return
      end

      circuits = BreakerMachines::Registry.instance.find_by_name(name.to_sym)

      if circuits.empty?
        puts "No circuits found with name: #{name}"
        return
      end

      circuits.each do |circuit|
        circuit.force_close
        puts "Forced close circuit: #{circuit.name} (now #{circuit.status_name})"
      end
    end

    def generate_report
      report = BreakerMachines::Registry.instance.detailed_report

      puts "\nFull Circuit Report"
      puts '=' * 80
      puts "Generated at: #{Time.now}"
      puts "Total circuits: #{report.size}"
      puts '=' * 80

      report.each do |circuit_data|
        puts "\nCircuit: #{circuit_data[:name]}"
        puts JSON.pretty_generate(circuit_data)
        puts '-' * 80
      end
    end

    def cleanup_registry
      before = BreakerMachines::Registry.instance.all_circuits.size
      BreakerMachines::Registry.instance.cleanup_dead_references
      after = BreakerMachines::Registry.instance.all_circuits.size

      removed = before - after
      puts "Cleaned up #{removed} dead circuit reference(s)."
    end

    def colorize_state(state)
      case state
      when :closed
        "\e[32m#{state}\e[0m" # Green
      when :open
        "\e[31m#{state}\e[0m"    # Red
      when :half_open
        "\e[33m#{state}\e[0m"    # Yellow
      else
        state.to_s
      end
    end

    def colorize_event_type(type)
      case type
      when :success
        "\e[32m#{type}\e[0m"     # Green
      when :failure
        "\e[31m#{type}\e[0m"     # Red
      when :state_change
        "\e[36m#{type}\e[0m"     # Cyan
      else
        type.to_s
      end
    end
  end
end
