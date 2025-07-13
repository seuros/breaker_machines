# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Apocalypse-resistant storage backend that tries multiple storage backends in sequence
    # Falls back to the next storage backend when the current one times out or fails
    #
    # NOTE: For DRb (distributed Ruby) environments, only :cache backend with external
    # cache stores (Redis, Memcached) will work properly. Memory-based backends (:memory,
    # :bucket_memory) are incompatible with DRb as they don't share state between processes.
    class FallbackChain < Base
      attr_reader :storage_configs, :storage_instances, :backend_states

      def initialize(storage_configs, circuit_breaker_threshold: 3, circuit_breaker_timeout: 30, **)
        super(**)
        @storage_configs = normalize_storage_configs(storage_configs)
        @storage_instances = {}
        @circuit_breaker_threshold = circuit_breaker_threshold
        @circuit_breaker_timeout = circuit_breaker_timeout
        @backend_states = @storage_configs.to_h do |config|
          [config[:backend], BackendState.new(config[:backend], threshold: @circuit_breaker_threshold, timeout: @circuit_breaker_timeout)]
        end
        validate_configs!
      end

      def get_status(circuit_name)
        execute_with_fallback(:get_status, circuit_name)
      end

      def set_status(circuit_name, status, opened_at = nil)
        execute_with_fallback(:set_status, circuit_name, status, opened_at)
      end

      def record_success(circuit_name, duration)
        execute_with_fallback(:record_success, circuit_name, duration)
      end

      def record_failure(circuit_name, duration)
        execute_with_fallback(:record_failure, circuit_name, duration)
      end

      def success_count(circuit_name, window_seconds)
        execute_with_fallback(:success_count, circuit_name, window_seconds)
      end

      def failure_count(circuit_name, window_seconds)
        execute_with_fallback(:failure_count, circuit_name, window_seconds)
      end

      def clear(circuit_name)
        execute_with_fallback(:clear, circuit_name)
      end

      def clear_all
        execute_with_fallback(:clear_all)
      end

      def record_event_with_details(circuit_name, type, duration, error: nil, new_state: nil)
        execute_with_fallback(:record_event_with_details, circuit_name, type, duration, error: error,
                                                                                        new_state: new_state)
      end

      def event_log(circuit_name, limit)
        execute_with_fallback(:event_log, circuit_name, limit)
      end

      def with_timeout(_timeout_ms)
        # FallbackChain doesn't use timeout directly - each backend handles its own
        yield
      end

      def cleanup!
        storage_instances.each_value do |instance|
          instance.clear_all if instance.respond_to?(:clear_all)
        end
        storage_instances.clear
        backend_states.each_value(&:reset)
      end

      private

      def execute_with_fallback(method, *args, **kwargs)
        chain_started_at = BreakerMachines.monotonic_time
        attempted_backends = []

        storage_configs.each_with_index do |config, index|
          backend_type = config[:backend]
          attempted_backends << backend_type
          backend_state = backend_states[backend_type]

          if backend_state.unhealthy_due_to_timeout?
            emit_backend_skipped_notification(backend_type, method, index)
            next
          end

          begin
            backend = get_backend_instance(backend_type)
            started_at = BreakerMachines.monotonic_time

            result = backend.with_timeout(config[:timeout]) do
              if kwargs.any?
                backend.send(method, *args, **kwargs)
              else
                backend.send(method, *args)
              end
            end

            duration_ms = ((BreakerMachines.monotonic_time - started_at) * 1000).round(2)
            emit_operation_success_notification(backend_type, method, duration_ms, index)
            reset_backend_failures(backend_type)

            chain_duration_ms = ((BreakerMachines.monotonic_time - chain_started_at) * 1000).round(2)
            emit_chain_success_notification(method, attempted_backends, backend_type, chain_duration_ms)

            return result
          rescue BreakerMachines::StorageTimeoutError, BreakerMachines::StorageError, StandardError => e
            duration_ms = ((BreakerMachines.monotonic_time - started_at) * 1000).round(2)
            record_backend_failure(backend_type, e, duration_ms)
            emit_fallback_notification(backend_type, e, duration_ms, index)

            if index == storage_configs.size - 1
              chain_duration_ms = ((BreakerMachines.monotonic_time - chain_started_at) * 1000).round(2)
              emit_chain_failure_notification(method, attempted_backends, chain_duration_ms)
              raise e
            end

            next
          end
        end

        chain_duration_ms = ((BreakerMachines.monotonic_time - chain_started_at) * 1000).round(2)
        emit_chain_failure_notification(method, attempted_backends, chain_duration_ms)
        raise BreakerMachines::StorageError, 'All storage backends are unhealthy'
      end

      def get_backend_instance(backend_type)
        storage_instances[backend_type] ||= create_backend_instance(backend_type)
      end

      def create_backend_instance(backend_type)
        case backend_type
        when :memory
          Memory.new
        when :bucket_memory
          BucketMemory.new
        when :cache
          Cache.new
        when :null
          Null.new
        else
          # Allow custom backend classes
          raise ConfigurationError, "Unknown storage backend: #{backend_type}" unless backend_type.is_a?(Class)

          backend_type.new

        end
      end

      def record_backend_failure(backend_type, _error, _duration_ms)
        backend_state = backend_states[backend_type]
        return unless backend_state

        previous_health = backend_state.health_name
        backend_state.record_failure
        new_health = backend_state.health_name

        if new_health != previous_health
          emit_backend_health_change_notification(backend_type, previous_health, new_health, backend_state.failure_count)
        end
      rescue StandardError => e
        # Don't let failure recording cause the whole chain to hang
        Rails.logger&.error("FallbackChain: Failed to record backend failure: #{e.message}")
      end

      def reset_backend_failures(backend_type)
        backend_state = backend_states[backend_type]
        return unless backend_state&.unhealthy?

        previous_health = backend_state.health_name
        backend_state.reset
        new_health = backend_state.health_name

        if new_health != previous_health
          emit_backend_health_change_notification(backend_type, previous_health, new_health, 0)
        end
      end

      def emit_fallback_notification(backend_type, error, duration_ms, backend_index)
        ActiveSupport::Notifications.instrument(
          'storage_fallback.breaker_machines',
          backend: backend_type,
          error_class: error.class.name,
          error_message: error.message,
          duration_ms: duration_ms,
          backend_index: backend_index,
          next_backend: storage_configs[backend_index + 1]&.dig(:backend)
        )
      end

      def emit_operation_success_notification(backend_type, method, duration_ms, backend_index)
        ActiveSupport::Notifications.instrument(
          'storage_operation.breaker_machines',
          backend: backend_type,
          operation: method,
          duration_ms: duration_ms,
          backend_index: backend_index,
          success: true
        )
      end

      def emit_backend_skipped_notification(backend_type, method, backend_index)
        backend_state = backend_states[backend_type]
        ActiveSupport::Notifications.instrument(
          'storage_backend_skipped.breaker_machines',
          backend: backend_type,
          operation: method,
          backend_index: backend_index,
          reason: 'unhealthy',
          unhealthy_until: backend_state&.instance_variable_get(:@unhealthy_until)
        )
      end

      def emit_backend_health_change_notification(backend_type, previous_state, new_state, failure_count)
        backend_state = backend_states[backend_type]
        ActiveSupport::Notifications.instrument(
          'storage_backend_health.breaker_machines',
          backend: backend_type,
          previous_state: previous_state,
          new_state: new_state,
          failure_count: failure_count,
          threshold: backend_state&.instance_variable_get(:@threshold),
          recovery_time: new_state == :unhealthy ? backend_state&.instance_variable_get(:@unhealthy_until) : nil
        )
      end

      def emit_chain_success_notification(method, attempted_backends, successful_backend, duration_ms)
        ActiveSupport::Notifications.instrument(
          'storage_chain_operation.breaker_machines',
          operation: method,
          attempted_backends: attempted_backends,
          successful_backend: successful_backend,
          duration_ms: duration_ms,
          success: true,
          fallback_count: attempted_backends.index(successful_backend)
        )
      end

      def emit_chain_failure_notification(method, attempted_backends, duration_ms)
        ActiveSupport::Notifications.instrument(
          'storage_chain_operation.breaker_machines',
          operation: method,
          attempted_backends: attempted_backends,
          successful_backend: nil,
          duration_ms: duration_ms,
          success: false,
          fallback_count: attempted_backends.size
        )
      end

      def normalize_storage_configs(configs)
        return configs if configs.is_a?(Array)

        # Convert hash format to array format
        unless configs.is_a?(Hash)
          raise ConfigurationError, "Storage configs must be Array or Hash, got: #{configs.class}"
        end

        configs.map do |_key, value|
          if value.is_a?(Hash)
            value
          else
            { backend: value, timeout: 5 }
          end
        end
      end

      def validate_configs!
        raise ConfigurationError, 'Storage configs cannot be empty' if storage_configs.empty?

        storage_configs.each_with_index do |config, index|
          unless config.is_a?(Hash) && config[:backend] && config[:timeout]
            raise ConfigurationError, "Invalid storage config at index #{index}: #{config}"
          end

          unless config[:timeout].is_a?(Numeric) && config[:timeout].positive?
            raise ConfigurationError, "Timeout must be a positive number, got: #{config[:timeout]}"
          end
        end
      end
    end
  end
end