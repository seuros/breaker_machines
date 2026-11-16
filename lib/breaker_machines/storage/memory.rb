# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Shares state between circuits of the same name in one process. Keeps
    # the newest `max_events` events per circuit.
    class Memory
      def initialize(max_events: 1000)
        @max_events = max_events
        @records = {}
        @events = Hash.new { |hash, name| hash[name] = [] }
        @mutex = Mutex.new
      end

      def read_status(name) = @mutex.synchronize { @records[name] }

      def write_status(name, record)
        raise TypeError, 'record must be a BreakerMachines::Storage::Record' unless record.instance_of?(Record)

        @mutex.synchronize { @records[name] = record }
        true
      end

      def record_event(name, event)
        raise TypeError, 'event must be a BreakerMachines::Event' unless event.instance_of?(Event)

        @mutex.synchronize do
          events = @events[name]
          events << event
          events.shift(events.size - @max_events) if events.size > @max_events
        end
        true
      end

      def event_log(name, limit) = @mutex.synchronize { @events.fetch(name, []).last(limit) }

      def clear(name)
        @mutex.synchronize do
          @records.delete(name)
          @events.delete(name)
        end
        nil
      end

      def clear_all
        @mutex.synchronize do
          @records.clear
          @events.clear
        end
        nil
      end
    end
  end
end
