# frozen_string_literal: true

module BreakerMachines
  # Hedged requests and multi-backend execution for Circuit. Delays are
  # Integer nanoseconds, every wait is clamped to the caller's
  # deadline_machines budget, and a hedge that loses is abandoned (its
  # thread killed, or its task stopped in fiber-safe mode).
  module Hedging
    # Nanoseconds between checks of the hedges' results.
    POLL = 1_000_000

    private

    def configure_hedging(hedged, backends)
      @hedged = hedged && { delay: hedged.fetch(:delay, 0), max_requests: hedged.fetch(:max_requests, 2) }
      @backends = backends && Array(backends)
      validate_hedging
    end

    def validate_hedging
      if @hedged
        delay, max = @hedged.values_at(:delay, :max_requests)
        raise TypeError, 'hedged delay must be Integer nanoseconds' unless delay.is_a?(Integer)
        raise RangeError, 'hedged delay must be >= 0' if delay.negative?
        raise RangeError, 'hedged max_requests must be an Integer >= 1' unless max.is_a?(Integer) && max.positive?
      end
      return unless @backends
      raise ArgumentError, 'backends must not be empty' if @backends.empty?
      raise TypeError, 'every backend must respond to #call' unless @backends.all? { it.respond_to?(:call) }
    end

    def hedging? = !@hedged.nil? || !@backends.nil?

    # The callables a call runs: the backends, or the block repeated for each
    # hedge.
    def hedge(&block)
      callables = @backends || Array.new(@hedged.fetch(:max_requests), block)
      return failover(callables) unless @hedged
      return callables.first.call if callables.size == 1

      @fiber_safe ? race_async(callables) : race_threads(callables)
    end

    # No hedging: each backend in turn until one succeeds.
    def failover(callables)
      last = nil
      callables.each do |callable|
        DeadlineMachines.check!
        return callable.call
      rescue *@exceptions => e
        last = e
      end
      raise last
    end

    def hedge_delay = DeadlineMachines.clamp_sleep(@hedged.fetch(:delay))

    def race_threads(callables)
      results = Queue.new
      threads = []
      callables.each_with_index do |callable, index|
        break unless results.empty?

        if index.positive?
          delay = hedge_delay
          sleep(delay.fdiv(1_000_000_000)) if delay.positive?
        end
        threads << Thread.new { attempt(callable, results) }
      end
      first_success(results, threads.size)
    ensure
      threads&.each(&:kill)
    end

    def race_async(callables)
      require 'async'
      Sync do |task|
        results = Async::Queue.new
        tasks = []
        callables.each_with_index do |callable, index|
          if index.positive?
            delay = hedge_delay
            task.sleep(delay.fdiv(1_000_000_000)) if delay.positive?
          end
          tasks << task.async { attempt(callable, results) }
        end
        first_success(results, tasks.size)
      ensure
        tasks&.each(&:stop)
      end
    end

    def attempt(callable, results)
      results << [:ok, callable.call]
    rescue StandardError => e
      results << [:error, e]
    end

    # The first success, or the last error once every hedge failed.
    def first_success(results, count)
      error = nil
      count.times do
        kind, value = results.pop
        return value if kind == :ok

        error = value
      end
      raise error
    end
  end

  # Fallbacks raced in parallel: the first one that returns wins; when all
  # raise, ParallelFallbackError carries their errors.
  class ParallelFallback
    attr_reader :fallbacks

    def initialize(fallbacks)
      raise ArgumentError, 'parallel fallbacks must not be empty' if fallbacks.empty?

      @fallbacks = fallbacks.dup.freeze
      freeze
    end

    def call(error, fiber_safe: false)
      return resolve(@fallbacks.first, error) if @fallbacks.size == 1

      fiber_safe ? race_async(error) : race_threads(error)
    end

    private

    def resolve(fallback, error)
      return fallback unless fallback.respond_to?(:call)

      fallback.arity.zero? ? fallback.call : fallback.call(error)
    end

    def race_threads(error)
      results = Queue.new
      threads = @fallbacks.map { |fallback| Thread.new { outcome(fallback, error, results) } }
      collect(results)
    ensure
      threads&.each(&:kill)
    end

    def race_async(error)
      require 'async'
      Sync do |task|
        results = Async::Queue.new
        tasks = @fallbacks.map { |fallback| task.async { outcome(fallback, error, results) } }
        collect(results)
      ensure
        tasks&.each(&:stop)
      end
    end

    def outcome(fallback, error, results)
      results << [:ok, resolve(fallback, error)]
    rescue StandardError => e
      results << [:error, e]
    end

    def collect(results)
      errors = []
      @fallbacks.size.times do
        kind, value = results.pop
        return value if kind == :ok

        errors << value
      end
      raise ParallelFallbackError.new('All parallel fallbacks failed', errors)
    end
  end
end
