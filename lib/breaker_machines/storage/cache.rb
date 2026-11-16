# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Shares state across processes through a cache store answering
    # `read(key)`, `write(key, value, expires_in:)` and `delete(key)`, such as
    # Rails.cache or any ActiveSupport::Cache::Store. Records and events are
    # stored as plain arrays and validated through `new` on read.
    #
    # `expires_in` is in seconds, as the cache store takes it (the store's
    # unit, not the core's); `max_events` bounds the shared event log.
    class Cache
      attr_reader :store, :prefix

      def initialize(store, prefix: 'breaker_machines', expires_in: 300, max_events: 100)
        %i[read write delete].each do |method|
          raise TypeError, "store must respond to ##{method}" unless store.respond_to?(method)
        end
        @store = store
        @prefix = prefix
        @expires_in = expires_in
        @max_events = max_events
        @names = Set.new
        @mutex = Mutex.new
      end

      def read_status(name)
        data = @store.read(key(name, 'status'))
        data && Record.load(data)
      end

      def write_status(name, record)
        raise TypeError, 'record must be a BreakerMachines::Storage::Record' unless record.instance_of?(Record)

        remember(name)
        @store.write(key(name, 'status'), record.dump, expires_in: @expires_in)
        true
      end

      # Read-modify-write of the shared log: concurrent writers may drop an
      # event (observability only; no decision reads it).
      def record_event(name, event)
        raise TypeError, 'event must be a BreakerMachines::Event' unless event.instance_of?(Event)

        remember(name)
        events = Array(@store.read(key(name, 'events')))
        events = (events + [Storage.dump_event(event)]).last(@max_events)
        @store.write(key(name, 'events'), events, expires_in: @expires_in)
        true
      end

      def event_log(name, limit)
        Array(@store.read(key(name, 'events'))).last(limit).map { |data| Storage.load_event(data) }
      end

      def clear(name)
        @store.delete(key(name, 'status'))
        @store.delete(key(name, 'events'))
        nil
      end

      # Clears every circuit this backend wrote to in this process.
      def clear_all
        names = @mutex.synchronize { @names.to_a }
        names.each { |name| clear(name) }
        nil
      end

      private

      def key(name, part) = "#{@prefix}:#{name}:#{part}"

      def remember(name) = @mutex.synchronize { @names << name }
    end
  end
end
