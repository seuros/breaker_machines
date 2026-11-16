# frozen_string_literal: true

require 'weakref'

module BreakerMachines
  # Counts over a circuit's window and its half-open visit. Instants are
  # Integer nanoseconds on the circuit's clock.
  Stats = Data.define(
    :state,
    :failure_count,
    :success_count,
    :last_failure_at,
    :opened_at,
    :half_open_attempts,
    :half_open_successes
  )
  # Sealed like the core values: no subclass, no bare `allocate`.
  Stats.singleton_class.undef_method(:allocate)
  Stats.define_singleton_method(:inherited) { |_| raise TypeError, "#{Stats} cannot be subclassed" }

  # A named circuit guarding blocks: the pure-Ruby runtime over a native
  # Breaker. The Breaker decides every admission and transition; the
  # circuit's lifecycle (`status`: closed, open, half_open) is a
  # `state_machines` machine with no guards, moved only by replaying the
  # Breaker's answers, so the two never disagree. Its `after_transition`
  # hooks run the circuit's hooks once no lock is held.
  #
  # `Circuit.new(name, policy, **runtime)` takes the core's Policy as it is.
  # Every keyword is the runtime's own, none of them a default the core
  # lacks:
  #
  # - `fallback:` replaces a refused or failed call: a Proc (called with the
  #   error, or with nothing when it takes no argument), an Array of them
  #   tried in order, a ParallelFallback raced, or any other value.
  # - `exceptions:` the errors that count as failures (StandardError). Any
  #   other exception, `throw` or `break` passes through uncounted.
  # - `on_open:`, `on_close:`, `on_half_open:`, `on_reject:` hooks, run with no
  #   lock held; a hook that raises is reported (`callback_error`) and ignored.
  # - `owner:` hooks and fallbacks run `instance_exec`'d on it (held weakly).
  # - `scope:` the Breaker's ticket scope (0).
  # - `storage:` a backend sharing the circuit's Status with other circuits
  #   of the same name (see Storage). Without one the circuit is alone.
  # - `clock:` a callable answering Integer nanoseconds. Default:
  #   BreakerMachines.monotonic_time, or BreakerMachines.wall_time with a
  #   storage, since circuits in other processes must read the same clock.
  #   A reading behind the latest one the breaker honoured reads as that one.
  # - `random:` the source of draws for jittered cooldowns (Random.new).
  # - `timeout:` Integer nanoseconds a call may take: in fiber-safe mode an
  #   Async timeout (CircuitTimeoutError, counted); otherwise a
  #   deadline_machines scope the block must check (cooperative, never
  #   forceful). The block is called with no argument either way; the scope
  #   is ambient, read with DeadlineMachines.current.
  # - `fiber_safe:` run calls, hedges and parallel fallbacks on the `async`
  #   gem's tasks (BreakerMachines.config.fiber_safe).
  # - `hedged:` `{ delay:, max_requests: }` (delay Integer ns): send the block
  #   again after each delay, first success wins.
  # - `backends:` callables tried as hedges (with `hedged:`) or in turn.
  # - `auto_register:` register with BreakerMachines.registry (true).
  class Circuit
    include Hedging

    TRANSITION_HOOKS = { open: :on_open, closed: :on_close, half_open: :on_half_open }.freeze
    INSTRUMENT = { open: 'opened', closed: 'closed', half_open: 'half_opened' }.freeze
    OBSERVED = {
      counted: [], opened: [:opened], closed: [:close], half_opened: [:attempt_recovery],
      half_opened_and_reopened: %i[attempt_recovery reopen], half_opened_and_closed: %i[attempt_recovery close],
      exhausted: []
    }.freeze
    ADOPTED = {
      unchanged: nil, opened: :sync_open, closed: :sync_close, half_opened: :sync_half_open, exhausted: nil
    }.freeze
    private_constant :TRANSITION_HOOKS, :INSTRUMENT, :OBSERVED, :ADOPTED

    state_machine :status, initial: :closed do
      event(:trip) { transition closed: :open }
      event(:reopen) { transition half_open: :open }
      event(:attempt_recovery) { transition open: :half_open }
      event(:close) { transition half_open: :closed }
      event(:forced_open) { transition any => :open }
      event(:forced_close) { transition %i[open half_open] => :closed }
      event(:hard_reset) { transition any => :closed }
      event(:sync_open) { transition any => :open }
      event(:sync_close) { transition any => :closed }
      event(:sync_half_open) { transition any => :half_open }

      after_transition do |circuit, transition|
        circuit.__send__(:transitioned, transition.to_name) unless transition.event == :hard_reset
      end
    end

    attr_reader :name, :policy, :storage, :last_error, :last_failure_at

    def initialize(name, policy, fallback: nil, exceptions: [StandardError], on_open: nil, on_close: nil,
                   on_half_open: nil, on_reject: nil, owner: nil, scope: 0,
                   storage: BreakerMachines.config.default_storage, clock: nil,
                   random: Random.new, timeout: nil, fiber_safe: BreakerMachines.config.fiber_safe,
                   hedged: nil, backends: nil, auto_register: true)
      @breaker = Breaker.with_scope(policy, scope)
      @policy = @breaker.policy
      @name = name
      @fallback = fallback
      @exceptions = exceptions
      @hooks = { on_open:, on_close:, on_half_open:, on_reject: }
      @owner = owner && (owner.is_a?(WeakRef) ? owner : WeakRef.new(owner))
      @storage = storage
      @clock = clock || (storage ? BreakerMachines.method(:wall_time) : BreakerMachines.method(:monotonic_time))
      @random = random
      @timeout = timeout
      @fiber_safe = fiber_safe
      configure_hedging(hedged, backends)
      @mutex = Mutex.new
      @pending = nil
      @generation = 0
      @last_error = nil
      @last_failure_at = nil
      super()
      sync_from_storage
      BreakerMachines.registry.register(self) if auto_register
    end

    # Run the block (or the backends) if the circuit admits it and record
    # the outcome. A refused call raises CircuitOpenError or
    # CircuitBulkheadError unless a fallback replaces it; a failure in
    # `exceptions` is recorded and re-raised unless a fallback replaces it.
    # A failure raised because the caller's own deadline_machines budget ran
    # out is abandoned, not recorded.
    def call(&block)
      raise ArgumentError, 'Circuit#call needs a block' unless block || @backends

      DeadlineMachines.check!
      ticket = admit
      return refused(ticket) unless ticket.is_a?(Ticket)

      begin
        result = execute(&block)
        settle(ticket, :success)
        result
      rescue *@exceptions => e
        failed(ticket, e)
      ensure
        abandon(ticket) unless ticket.settled
      end
    end
    alias wrap call

    # Record an operation that ran outside this circuit's admission
    # (`:success` or `:failure`, taking `took` nanoseconds) and answer the
    # state it left the circuit in.
    def observe(outcome, took)
      sync_from_storage
      decide do |now|
        before = status_name
        events = OBSERVED.fetch(@breaker.observe(outcome, took, now, draw))
        events.map { |event| event == :opened ? opened_event(before) : event }
      end
      state
    end

    # Open the circuit whatever its threshold says, restarting the cooldown.
    def force_open
      decide { |now| @breaker.force_open(now, draw) == :opened ? [:forced_open] : [] }
      self
    end

    # Close the circuit whatever its threshold says, keeping its window.
    def force_close
      decide { @breaker.force_close == :closed ? [:forced_close] : [] }
      self
    end

    # Close the circuit and clear its window and shared events; fires no
    # hook.
    def reset
      decide do
        # No transition epoch left: nothing was reset, nothing is cleared.
        next [] if @breaker.reset == :exhausted

        @storage&.clear(@name)
        [:hard_reset]
      end
      @last_error = nil
      @last_failure_at = nil
      self
    end

    # :closed, :open or :half_open, as the lifecycle machine holds it.
    def state = status_name

    def open? = state == :open
    def closed? = state == :closed
    def half_open? = state == :half_open

    # The circuit's clock reading, never behind the latest honoured instant.
    def now = [@clock.call, @breaker.latest].max

    def opened_at = @breaker.opened_at

    # Nanoseconds until a probe may run, while the circuit is open.
    def retry_after = @breaker.retry_after(now)

    # The newest `limit` outcomes, oldest first: the shared ones when a
    # storage keeps them, this process's otherwise.
    def events(limit = 20)
      shared = @storage&.event_log(@name, limit)
      shared.nil? || shared.empty? ? @breaker.events(limit) : shared
    end

    # The native decision core, read-only queries welcome.
    attr_reader :breaker

    def stats
      at = now
      Stats.new(
        state:, failure_count: @breaker.failures(at), success_count: @breaker.successes(at),
        last_failure_at:, opened_at:, half_open_attempts: @breaker.half_open_attempts,
        half_open_successes: @breaker.half_open_successes
      )
    end

    def to_h
      { name:, state:, stats: stats.to_h, policy: policy.to_h, last_error: last_error&.message }
    end

    # One line for consoles and logs.
    def summary
      retry_in = retry_after
      tail = retry_in ? ", probing in #{retry_in.fdiv(1_000_000_000).round(1)}s" : ''
      "Circuit '#{name}' is #{state.upcase} (#{stats.failure_count} failures in the window#{tail})."
    end

    private

    def draw = @random.rand(2**64)

    # Decide under the lock: the block runs native calls with the clock read
    # inside it and answers the lifecycle events replaying the Breaker's
    # answers. The machine moves under the lock, and a transition is stored
    # for other circuits of this name (unless it was adopted from them); the
    # hooks the transitions queued run once the lock is released.
    def decide(share: true)
      transitions = @mutex.synchronize do
        @pending = []
        events = Array(yield([@clock.call, @breaker.latest].max))
        events.each { |event| __send__(:"#{event}!") }
        check_agreement(events)
        publish if share && !events.empty?
        @pending
      ensure
        @pending = nil
      end
      transitions.each { |transition| announce(transition) }
    end

    # The machine replays the core's answers in order, so once they are all
    # replayed it holds the core's state; anything else is a bug, raised.
    def check_agreement(events)
      return if status_name == @breaker.state

      raise "lifecycle #{status_name} diverged from the core's #{@breaker.state} after #{events.inspect}"
    end

    # Queued by the machine's after_transition, under the lock.
    def transitioned(to) = @pending << to

    def announce(state)
      run_hook(TRANSITION_HOOKS.fetch(state))
      BreakerMachines.instrument(INSTRUMENT.fetch(state), circuit: @name)
    end

    def opened_event(before) = before == :half_open ? :reopen : :trip

    def admit
      sync_from_storage
      ticket = nil
      decide do |now|
        ticket = @breaker.admit(now)
        ticket.is_a?(Ticket) && ticket.admission == :half_opened ? [:attempt_recovery] : []
      end
      ticket
    end

    def settle(ticket, outcome)
      answer = nil
      decide do |now|
        before = status_name
        answer = @breaker.complete(ticket, outcome, now, draw)
        case answer
        when :opened then [opened_event(before)]
        when :closed then [:close]
        else []
        end
      end
      share_event(ticket, outcome)
      answer
    end

    def abandon(ticket) = @mutex.synchronize { @breaker.abandon(ticket) }

    def execute(&)
      return run_with_timeout(&) unless hedging?

      run_with_timeout { hedge(&) }
    end

    # The block is called with no argument in every mode: the deadline scope
    # is ambient (DeadlineMachines.current), never yielded, and the Async
    # timer stays internal.
    def run_with_timeout(&block)
      return yield unless @timeout
      return async_timeout(&block) if @fiber_safe

      DeadlineMachines.with_deadline(@timeout) { block.call }
    end

    def async_timeout(&block)
      require 'async'
      task = Async::Task.current?
      return Sync { async_timeout(&block) } unless task

      task.with_timeout(@timeout.fdiv(1_000_000_000)) { block.call }
    rescue Async::TimeoutError
      raise CircuitTimeoutError.new(@name, @timeout)
    end

    def failed(ticket, error)
      raise error if caller_gave_up?(error)

      settle(ticket, :failure)
      @last_error = error
      @last_failure_at = now
      raise error unless @fallback

      run_fallback(error)
    end

    # A caller abandoning its own budget says nothing about the dependency's
    # health; an inner scope expiring is a genuine timeout and still counts.
    def caller_gave_up?(error)
      error.is_a?(DeadlineMachines::Error) && DeadlineMachines.current&.done?
    end

    def refused(refusal)
      run_hook(:on_reject)
      BreakerMachines.instrument('rejected', circuit: @name, refusal:)
      error_class = refusal == :full ? CircuitBulkheadError : CircuitOpenError
      error = error_class.new(@name, refusal, retry_after)
      raise error unless @fallback

      run_fallback(error)
    end

    def run_hook(name)
      hook = @hooks[name]
      run(hook) if hook
    rescue StandardError => e
      BreakerMachines.instrument('callback_error', circuit: @name, callback: name, error: e)
      nil
    end

    def run_fallback(error)
      return @fallback.call(error, fiber_safe: @fiber_safe) if @fallback.is_a?(ParallelFallback)

      fallbacks = @fallback.is_a?(Array) ? @fallback : [@fallback]
      last = error
      fallbacks.each do |fallback|
        return fallback.is_a?(Proc) ? run(fallback, last) : fallback
      rescue StandardError => e
        last = e
      end
      raise last
    end

    def run(callable, *args)
      args = [] if callable.arity.zero?
      owner = resolve_owner
      owner ? owner.instance_exec(*args, &callable) : callable.call(*args)
    end

    def resolve_owner
      @owner&.__getobj__
    rescue WeakRef::RefError
      nil
    end

    # --- shared status ---------------------------------------------------

    # Adopt a newer Status another circuit of this name stored.
    def sync_from_storage
      return unless @storage

      record = read_record
      return unless record && record.generation > @generation

      decide(share: false) do
        @generation = record.generation
        Array(ADOPTED.fetch(@breaker.adopt(record.status)))
      end
    end

    def read_record
      @storage.read_status(@name)
    rescue StandardError => e
      BreakerMachines.instrument('storage_error', circuit: @name, error: e)
      nil
    end

    # Store this circuit's Status under the next generation, under the lock.
    def publish
      return unless @storage

      stored = read_record&.generation || 0
      @generation = [@generation, stored].max + 1
      @storage.write_status(@name, Storage::Record.new(@breaker.status, @generation))
    rescue StandardError => e
      BreakerMachines.instrument('storage_error', circuit: @name, error: e)
    end

    def share_event(ticket, outcome)
      return unless @storage

      at = now
      @storage.record_event(@name, Event.new(at, outcome, [at - ticket.admitted_at, 0].max))
    rescue StandardError => e
      BreakerMachines.instrument('storage_error', circuit: @name, error: e)
    end
  end
end
