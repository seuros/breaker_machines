# frozen_string_literal: true

require 'concurrent-ruby'

module BreakerMachines
  class Circuit
    # Base provides the common initialization and setup logic shared by all circuit types
    module Base
      extend ActiveSupport::Concern

      included do
        include Circuit::Configuration
        include Circuit::Execution
        include Circuit::HedgedExecution
        include Circuit::Introspection
        include Circuit::Callbacks
        include Circuit::StateCallbacks

        attr_reader :name, :config, :opened_at, :storage, :metrics, :semaphore
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
        @opened_at = Concurrent::AtomicReference.new(nil)
        @half_open_attempts = Concurrent::AtomicFixnum.new(0)
        @half_open_successes = Concurrent::AtomicFixnum.new(0)
        @mutex = Concurrent::ReentrantReadWriteLock.new
        @last_failure_at = Concurrent::AtomicReference.new(nil)
        @last_error = Concurrent::AtomicReference.new(nil)

        # Initialize semaphore for bulkheading if max_concurrent is set
        @semaphore = (Concurrent::Semaphore.new(@config[:max_concurrent]) if @config[:max_concurrent])

        restore_status_from_storage if @storage

        # Register with global registry unless auto_register is disabled
        BreakerMachines::Registry.instance.register(self) unless @config[:auto_register] == false
      end

      private

      def restore_status_from_storage
        stored_status = @storage.get_status(@name)
        return unless stored_status

        self.status = stored_status.status.to_s
        @opened_at.value = stored_status.opened_at if stored_status.opened_at
      end
    end
  end
end
