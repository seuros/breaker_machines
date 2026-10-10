# frozen_string_literal: true

module BreakerMachines
  class Circuit
    # Native circuit breaker implementation using Rust FFI
    #
    # This provides a high-performance circuit breaker with state machine logic
    # implemented in Rust. It's fully compatible with the Ruby circuit API but
    # significantly faster for high-throughput scenarios.
    #
    # @example Basic usage
    #   circuit = BreakerMachines::Circuit::Native.new('api_calls',
    #     failure_threshold: 5,
    #     failure_window_secs: 60.0
    #   )
    #
    #   circuit.call { api.fetch_data }
    class Native
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
      # @option options [Integer] :success_threshold Successes needed to close from half-open (default: 2)
      # @option options [Boolean] :auto_register Register with global registry (default: true)
      def initialize(name, options = {})
        unless BreakerMachines.native_available?
          raise BreakerMachines::ConfigurationError,
                'Native extension not available. Install with native support or use Circuit::Ruby'
        end

        @name = name
        @config = default_config.merge(options)

        # Create the native circuit breaker
        @native_circuit = BreakerMachinesNative::Circuit.new(
          name,
          {
            failure_threshold: @config[:failure_threshold],
            failure_window_secs: @config[:failure_window_secs],
            half_open_timeout_secs: @config[:half_open_timeout_secs],
            success_threshold: @config[:success_threshold]
          }
        )

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

      # Get current state name
      # @return [String] 'closed', 'open', or 'half_open'
      def state
        @native_circuit.state_name
      end

      # Reset the circuit (clear all events)
      def reset!
        @native_circuit.reset
      end

      # Get circuit status for inspection
      # @return [Hash] Status information
      def status
        {
          name: @name,
          state: state,
          open: open?,
          closed: closed?,
          config: @config
        }
      end

      private

      def default_config
        {
          failure_threshold: 5,
          failure_window_secs: 60.0,
          half_open_timeout_secs: 30.0,
          success_threshold: 2,
          auto_register: true
        }
      end
    end
  end
end
