# frozen_string_literal: true

require 'deadline_machines'
require_relative 'breaker_machines/version'

# Circuit breaker decisions over a native Rust core, and a runtime that
# guards blocks with them.
#
# The values below and BreakerMachines::Breaker mirror the core type of the
# same name, field for field, argument for argument. Every instant and span
# (`now`, `window`, `cooldown`, `took`) is Integer nanoseconds; every random
# draw is an Integer in 0...2**64. Refusals are Symbols (REFUSALS) and never
# raise; malformed input raises TypeError (wrong type) or RangeError (a value
# outside what the core accepts).
#
# The native side is the authority on every value it reads: one of this
# gem's classes must be exactly that class (a subclass is a TypeError) and
# every field is validated again through the core constructor, so a value
# forged past `initialize` (`Marshal.load`, a bound `Data#initialize`) never
# reaches the core.
module BreakerMachines
  # When a closed circuit opens: `count` failures in the window (an Integer
  # >= 1, or nil), or a failure share of at least `rate` (a real in
  # 0.0 < rate <= 1.0, or nil) once the window holds `minimum_calls`
  # outcomes. At least one of `count` and `rate` must be set.
  Threshold = Data.define(:count, :rate, :minimum_calls) do
    def initialize(count:, rate:, minimum_calls:)
      BreakerMachines.__send__(:native_threshold, count, rate, minimum_calls)
      super
    end
  end

  # How an open circuit recovers: it waits `cooldown` (Integer nanoseconds),
  # shortened by up to `jitter` of it (0.0..1.0, drawn once per opening), then
  # admits up to `half_open_calls` probes at a time; `success_threshold`
  # successful probes close it and one failed probe reopens it.
  Recovery = Data.define(:cooldown, :jitter, :success_threshold, :half_open_calls) do
    def initialize(cooldown:, jitter:, success_threshold:, half_open_calls:)
      BreakerMachines.__send__(:native_recovery, cooldown, jitter, success_threshold, half_open_calls)
      super
    end
  end

  # Everything a Breaker decides by: outcomes within the last `window`
  # (Integer nanoseconds, positive) judged by `threshold`, recovery by
  # `recovery`, at most `max_concurrent` tickets outstanding (nil: unbounded).
  Policy = Data.define(:threshold, :window, :recovery, :max_concurrent) do
    def initialize(threshold:, window:, recovery:, max_concurrent:)
      BreakerMachines.__send__(:native_policy, threshold, window, recovery, max_concurrent)
      super
    end
  end

  # The part of a breaker's state that may cross a process boundary: its
  # `state` and, while open, when it opened and may probe (Integer
  # nanoseconds on the clock every sharer reads; `opened_at <= retry_at`).
  # Closed and half-open statuses carry neither instant.
  Status = Data.define(:state, :opened_at, :retry_at) do
    def initialize(state:, opened_at:, retry_at:)
      BreakerMachines.__send__(:native_status, state, opened_at, retry_at)
      super
    end
  end

  # One outcome in a breaker's window: when it was recorded, `:success` or
  # `:failure`, and how long the operation ran.
  Event = Data.define(:at, :outcome, :took) do
    def initialize(at:, outcome:, took:)
      BreakerMachines.__send__(:native_event, at, outcome, took)
      super
    end
  end

  # Sealed: no subclass can skip the checks above by overriding `initialize`,
  # and no bare `allocate` builds a value that never ran them. Ruby still
  # binds a subclass constant before `inherited` raises; the native side
  # refuses its instances.
  [Threshold, Recovery, Policy, Status, Event].each do |value|
    value.singleton_class.undef_method(:allocate)
    value.define_singleton_method(:inherited) { |_| raise TypeError, "#{value} cannot be subclassed" }
  end
end

# Native is required: no algorithm fallback. It resolves the classes above
# once, here, and defines Breaker and Ticket.
require 'breaker_machines_native/breaker_machines_native'

module BreakerMachines
  class << self
    private :native_threshold, :native_recovery, :native_policy, :native_status, :native_event

    # The monotonic clock every runtime circuit reads by default, in Integer
    # nanoseconds.
    def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  end

  # Breaker and Ticket wrap native state and have no allocator: a subclass's
  # `new` would build the base class anyway, so subclassing raises too.
  [Breaker, Ticket].each do |wrapper|
    wrapper.define_singleton_method(:inherited) { |_| raise TypeError, "#{wrapper} cannot be subclassed" }
  end

  # The core's `Breaker`: admission, outcomes and transitions, with no clock
  # and no randomness of its own. Keeps the newest 1000 outcomes.
  #
  # `admit(now)` answers a Ticket or a refusal Symbol. `complete(ticket,
  # outcome, now, draw)` answers `:counted`, `:opened`, `:closed`, or
  # `:duplicate` (a repeat of the ticket's settlement; `Ticket#settled` holds
  # the original answer). `abandon(ticket)` answers `:released` or
  # `:duplicate`. `observe(outcome, took, now, draw)` answers `:counted`,
  # `:opened`, `:closed`, or, when an elapsed cooldown moved the circuit to
  # half-open first, `:half_opened`, `:half_opened_and_reopened` or
  # `:half_opened_and_closed`. `force_open(now, draw)` answers `:opened`;
  # `adopt(status)` answers `:unchanged`, `:opened`, `:closed` or
  # `:half_opened`;
  # `force_close` answers `:closed` or `:already_closed`; `reset` answers
  # nil. Every one of them may answer a refusal Symbol instead (see
  # REFUSALS): `:exhausted` once no transition epoch is left for a call
  # that would transition.
  class Breaker
    class << self
      # A closed breaker issuing tickets in scope zero.
      def new(policy) = native_new(policy)

      # A closed breaker issuing tickets in `scope` (0..65_535).
      def with_scope(policy, scope) = native_with_scope(policy, scope)

      private :native_new, :native_with_scope
    end
  end
end

require 'delegate'
require 'state_machines'
require_relative 'breaker_machines/errors'
require_relative 'breaker_machines/configuration'
require_relative 'breaker_machines/storage'
require_relative 'breaker_machines/hedging'
require_relative 'breaker_machines/circuit'
require_relative 'breaker_machines/async_circuit'
require_relative 'breaker_machines/coordinated_circuit'
require_relative 'breaker_machines/cascading_circuit'
require_relative 'breaker_machines/circuit_group'
require_relative 'breaker_machines/registry'
require_relative 'breaker_machines/dsl'
require_relative 'breaker_machines/console'

module BreakerMachines
  # The registry every circuit registers with unless told not to.
  def self.registry = Registry.instance
end
