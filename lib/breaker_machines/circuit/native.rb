# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Native circuit breaker implementation using Rust FFI
    #
    # This provides a high-performance circuit breaker with state machine logic
    # implemented in Rust. It answers the same questions as the pure-Ruby
    # circuit under the same names, so the global registry reports on both
    # kinds of circuit alike.
    #
    # @example Basic usage
    #   circuit = BreakerMachines::Circuit::Native.new('api_calls',
    #     failure_threshold: 5,
    #     failure_window_secs: 60.0
    #   )
    #
    #   circuit.call { api.fetch_data }
    class Native
      include Circuit::Protection

      # @return [String] Circuit name
      attr_reader :name

      # @return [Hash] Circuit configuration
      attr_reader :config

      # Create a new native circuit breaker
      #
      # @param name [String] Circuit name
      # @param options [Hash] Configuration options
      # @option options [Integer] :failure_threshold Number of failures to open circuit (default: 5)
      # @option options [Float] :failure_window_secs Time window for counting failures (default: 60.0)
      # @option options [Float] :half_open_timeout_secs Timeout before attempting reset (default: 30.0)
      # @option options [Float] :jitter_factor Cooldown jitter, 0.0-1.0 (default: 0.0)
      # @option options [Integer] :success_threshold Successes needed to close from half-open (default: 2)
      # @option options [Integer] :half_open_calls Probes admitted at a time while half-open (default: 1)
      # @option options [Boolean] :auto_register Register with global registry (default: true)
      # @raise [ConfigurationError] for an option the native circuit cannot honour
      def initialize(name, options = {})
        unless BreakerMachines.native_available?
          raise BreakerMachines::ConfigurationError,
                'Native extension not available. Install with native support or use Circuit::Ruby'
        end

        unhonoured = options.keys - default_config.keys
        if unhonoured.any?
          raise BreakerMachines::ConfigurationError,
                "Circuit::Native cannot honour #{unhonoured.join(', ')}; use BreakerMachines::Circuit for those"
        end

        @name = name
        @config = default_config.merge(options)

        # Create the native circuit breaker
        @native_circuit = BreakerMachinesNative::Circuit.new(name, native_config)

        # Zero of the native circuit's own clock, which its timestamps count from.
        @clock_origin = BreakerMachines.monotonic_time
        @epoch_origin = BreakerMachines.monotonic_to_epoch(@clock_origin)

        # Register with global registry unless disabled
        BreakerMachines::Registry.instance.register(self) unless @config[:auto_register] == false
      end

      # Execute a block with circuit breaker protection
      #
      # Admission, the open -> half-open cooldown, and half-open probe limits run
      # in the native circuit. A StandardError counts as a failure and is
      # re-raised; other exceptions and throw/break pass through uncounted.
      #
      # @yield Block to execute
      # @return Result of the block
      # @raise [CircuitOpenError] if circuit is open or its probe slots are taken
      def call(&)
        @native_circuit.call(&)
      end

      # Check if circuit is open
      # @return [Boolean]
      def open?
        @native_circuit.is_open
      end

      # Check if circuit is closed
      # @return [Boolean]
      def closed?
        @native_circuit.is_closed
      end

      # Check if circuit is half-open (probing for recovery)
      # @return [Boolean]
      def half_open?
        @native_circuit.is_half_open
      end

      # Current state name
      # @return [Symbol] :closed, :open, or :half_open
      def status_name
        @native_circuit.state_name.to_sym
      end

      # @return [BreakerMachines::Stats] counts over the configured failure window
      def stats
        BreakerMachines::Stats.new(
          state: status_name,
          failure_count: @native_circuit.failure_count,
          success_count: @native_circuit.success_count,
          last_failure_at: nil,
          opened_at: opened_at,
          half_open_attempts: @native_circuit.half_open_attempts,
          half_open_successes: @native_circuit.half_open_successes
        )
      end

      # @return [Hash] a copy of this circuit's configuration
      def configuration
        @config.dup
      end

      # @param limit [Integer] how many of the most recent outcomes to return
      # @return [Array<Hash>] recorded outcomes, oldest first
      def event_log(limit: 20)
        @native_circuit.event_log(limit).map do |event|
          event.merge(timestamp_epoch: @epoch_origin + event[:timestamp])
        end
      end

      # The native circuit records outcomes, not the errors behind them.
      # @return [nil]
      def last_error
        nil
      end

      # @return [nil] (see #last_error)
      def last_error_info
        nil
      end

      # @return [Hash] full state, statistics and configuration
      def to_h
        {
          name: @name,
          state: status_name,
          stats: stats.to_h,
          config: configuration,
          event_log: event_log,
          last_error: last_error_info&.to_h
        }
      end

      # Open the circuit whatever its failure count
      # @return [true]
      def force_open
        @native_circuit.force_open
        true
      end

      # Close the circuit, keeping the events in its failure window
      # @return [true]
      def force_close
        @native_circuit.force_close
        true
      end

      alias reset force_close
      alias reset! force_close

      # Close the circuit and clear its failure window
      # @return [true]
      def hard_reset
        @native_circuit.reset
        true
      end

      private

      # Native timestamps count from the circuit's own clock; Stats reports
      # BreakerMachines.monotonic_time.
      def opened_at
        opened = @native_circuit.opened_at
        opened && @clock_origin + opened
      end

      def default_config
        {
          failure_threshold: 5,
          failure_window_secs: 60.0,
          half_open_timeout_secs: 30.0,
          jitter_factor: 0.0,
          success_threshold: 2,
          half_open_calls: 1,
          auto_register: true
        }
      end

      def native_config
        @config.except(:auto_register)
      end
    end
  end
end
