# frozen_string_literal: true

require 'concurrent-ruby'

module BreakerMachines
  class Circuit
    # Base provides the common initialization and setup logic shared by all circuit types
    module Base
      extend ActiveSupport::Concern

      included do
        include Circuit::Configuration
        include Circuit::Admission
        include Circuit::Execution
        include Circuit::Protection
        include Circuit::HedgedExecution
        include Circuit::Introspection
        include Circuit::Callbacks
        include Circuit::StateCallbacks

        # name/config/opened_at readers are defined in Circuit::Configuration
        attr_reader :storage, :metrics, :semaphore
        attr_reader :half_open_attempts, :half_open_successes, :mutex
        attr_reader :last_failure_at, :last_error
      end

      def initialize(name, options = {})
        @name = name
        @config = default_config.merge(options)
        # Always use a storage backend for proper sliding window implementation
        # Use global default storage if not specified
        @storage = @config[:storage] || create_default_storage
        @metrics = @config[:metrics]
        initialize_runtime_state
      end

      private

      def initialize_runtime_state
        @opened_at = Concurrent::AtomicReference.new(nil)
        @half_open_attempts = Concurrent::AtomicFixnum.new(0)
        @half_open_successes = Concurrent::AtomicFixnum.new(0)
        @state_epoch = Concurrent::AtomicFixnum.new(0)
        @mutex = Concurrent::ReentrantReadWriteLock.new
        @last_failure_at = Concurrent::AtomicReference.new(nil)
        @last_error = Concurrent::AtomicReference.new(nil)

        # Initialize semaphore for bulkheading if max_concurrent is set
        @semaphore = (Concurrent::Semaphore.new(@config[:max_concurrent]) if @config[:max_concurrent])
      end

      # A round trip through epoch time is off by up to ~0.12µs (float64
      # spacing near today's epoch); any larger difference is another opening.
      OPENED_AT_TOLERANCE = 1e-6

      # Reads the shared status without taking the lock. True when it differs
      # from the last status this instance stored or observed.
      def stored_status_changed?
        stored_status = @storage&.get_status(@name)
        !stored_status.nil? && !same_stored_status?(stored_status, @stored_status)
      end

      def restore_status_from_storage
        stored_status = @storage&.get_status(@name)
        return if stored_status.nil? || same_stored_status?(stored_status, @stored_status)

        @stored_status = stored_status
        self.status = stored_status.status.to_s
        @opened_at.value = stored_status.opened_at
        @state_epoch.increment
        @half_open_attempts.value = 0
        @half_open_successes.value = 0
        return unless closed?

        @last_error.value = nil
        @last_failure_at.value = nil
      end

      def same_stored_status?(stored_status, known_status)
        return false unless known_status && stored_status.status == known_status.status

        stored_at = stored_status.opened_at
        known_at = known_status.opened_at
        return stored_at == known_at if stored_at.nil? || known_at.nil?

        (stored_at - known_at).abs <= OPENED_AT_TOLERANCE
      end

      # When the storage reports a failed write (false), keep the last status
      # observed there: the stale entry then reads as unchanged and cannot
      # undo this transition.
      def persist_status(status, opened_at = nil)
        return if @storage.nil? || @storage.set_status(@name, status, opened_at) == false

        @stored_status = BreakerMachines::Status.new(status: status, opened_at: opened_at)
      end
    end
  end
end
