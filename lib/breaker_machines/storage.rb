# frozen_string_literal: true

module BreakerMachines
  # Backends that share a circuit's state between circuits of the same name,
  # in one process (Memory) or across processes (Cache over a shared cache
  # store such as Rails.cache).
  #
  # What crosses the boundary is the core's own vocabulary: a Record holding
  # the Breaker's Status and a generation, and the Events a circuit
  # recorded. Backends that serialize them rebuild them through `new` on
  # read, so a stored value is validated like any other (an invalid one is
  # a StorageError, never adopted).
  #
  # Consistency limits:
  # - The lifecycle is shared; the outcome window is not. Each process
  #   judges its own failures against the threshold; one process opening
  #   (or recovering) moves every other on its next call.
  # - Writes are last-write-wins, ordered by generation: a circuit adopts a
  #   record only when its generation is newer than the last it saw. Two
  #   processes transitioning at once may both write the same generation;
  #   the later write wins and the other converges on its next read.
  # - Half-open probe limits and the concurrency limit are per process.
  # - Every Status instant is on the clock all sharers read: circuits with a
  #   storage default to BreakerMachines.wall_time.
  #
  # A backend answers `read_status(name)` (a Record or nil),
  # `write_status(name, record)`, `record_event(name, event)`,
  # `event_log(name, limit)` (Events, oldest first), `clear(name)` and
  # `clear_all`.
  module Storage
    # A shared status and the generation it was written under.
    Record = Data.define(:status, :generation) do
      def initialize(status:, generation:)
        raise TypeError, 'status must be a BreakerMachines::Status' unless status.instance_of?(Status)
        raise TypeError, 'generation must be an Integer' unless generation.is_a?(Integer)
        raise RangeError, 'generation must be >= 0' if generation.negative?

        super
      end

      # The record as plain data, for a serializing store.
      def dump = [status.state, status.opened_at, status.retry_at, generation]

      # A record from `dump`'s data, validated through Status.new.
      def self.load(data)
        state, opened_at, retry_at, generation = data
        new(Status.new(state, opened_at, retry_at), generation)
      rescue TypeError, RangeError, ArgumentError, NoMethodError => e
        raise StorageError, "invalid stored status: #{e.message}"
      end
    end

    # Sealed like the core values: no subclass skips the checks, no bare
    # `allocate` builds one.
    Record.singleton_class.undef_method(:allocate)
    Record.define_singleton_method(:inherited) { |_| raise TypeError, "#{Record} cannot be subclassed" }

    # An event as plain data, and back through Event.new.
    def self.dump_event(event) = [event.at, event.outcome, event.took]

    def self.load_event(data)
      Event.new(*data)
    rescue TypeError, RangeError, ArgumentError => e
      raise StorageError, "invalid stored event: #{e.message}"
    end
  end
end

require_relative 'storage/memory'
require_relative 'storage/null'
require_relative 'storage/cache'
require_relative 'storage/fallback_chain'
