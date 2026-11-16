# frozen_string_literal: true

require_relative 'test_helper'
require 'async'
require 'active_support'
require 'active_support/notifications'
require 'stringio'

class RuntimeFeaturesTest < Minitest::Test
  include BreakerHelpers

  def teardown
    B.registry.clear
    B.reset!
  end

  def test_hedged_requests_answer_the_first_success
    calls = Queue.new
    c = B::Circuit.new(:hedged, policy, hedged: { delay: 1_000_000, max_requests: 3 })
    result = c.call do
      calls << 1
      next :fast unless calls.size == 1

      sleep 0.2
      :slow
    end
    assert_equal :fast, result
    assert_raises(TypeError) { B::Circuit.new(:bad, policy, hedged: { delay: 0.05 }) }
    assert_raises(RangeError) { B::Circuit.new(:bad, policy, hedged: { delay: 1, max_requests: 0 }) }
  end

  def test_backends_fail_over_in_turn_or_race_when_hedged
    failing = -> { raise IOError, 'primary down' }
    c = B::Circuit.new(:backends, policy, backends: [failing, -> { :secondary }])
    assert_equal :secondary, c.call
    raced = B::Circuit.new(:raced, policy(failures: 1), backends: [failing, failing], hedged: { delay: 0 })
    assert_raises(IOError) { raced.call }
    assert_predicate raced, :open?
    assert_raises(ArgumentError) { B::Circuit.new(:empty, policy, backends: []) }
  end

  def test_parallel_fallbacks_race_and_collect_errors
    c = B::Circuit.new(:parallel, policy(failures: 1),
                       fallback: B::ParallelFallback.new([-> { raise 'a' }, ->(error) { "saved #{error.class}" }]))
    assert_equal 'saved IOError', c.call { raise IOError }
    all_fail = B::Circuit.new(:doomed, policy(failures: 1), fallback: B::ParallelFallback.new([-> { raise 'a' },
                                                                                               -> { raise 'b' }]))
    error = assert_raises(B::ParallelFallbackError) { all_fail.call { raise IOError } }
    assert_equal %w[a b], error.errors.map(&:message).sort
  end

  def test_async_circuits_run_as_tasks
    c = B::AsyncCircuit.new(:async, policy(failures: 1))
    Sync do
      assert_equal :ok, c.call_async { :ok }.wait
      c.fire_async(:force_open).wait
      assert_predicate c, :open?
      health = c.health_check_async.wait
      assert_equal %i[async open], health.values_at(:name, :state)
    end
    assert_raises(ArgumentError) { c.fire_async(:trip) }
  end

  def test_fiber_safe_timeouts_count_as_failures
    c = B::Circuit.new(:slow, policy(failures: 1), fiber_safe: true, timeout: 10_000_000)
    assert_raises(B::CircuitTimeoutError) { Sync { c.call { sleep 1 } } }
    assert_predicate c, :open?
    fast = B::Circuit.new(:fast, policy, fiber_safe: true, timeout: at(1), hedged: { delay: 0, max_requests: 2 })
    assert_equal :ok, Sync { fast.call { :ok } }
  end

  def test_sync_timeouts_are_cooperative_deadlines
    c = B::Circuit.new(:cooperative, policy(failures: 1), timeout: 1_000)
    assert_raises(DeadlineMachines::Exceeded) do
      c.call do
        sleep 0.001
        DeadlineMachines.check!
      end
    end
    assert_predicate c, :open?, 'an inner scope expiring is a genuine timeout'
  end

  # The block is called with no argument in every mode: under `timeout:` the
  # deadline scope is ambient (DeadlineMachines.current), never yielded.
  def test_blocks_are_called_with_no_argument_with_or_without_timeout
    modes = { plain: {}, deadline: { timeout: at(1) }, fiber_safe: { timeout: at(1), fiber_safe: true } }
    modes.each do |mode, runtime|
      c = B::Circuit.new(:"argless_#{mode}", policy(failures: 1), **runtime)
      assert_equal :lambda, c.call(&-> { :lambda }), mode
      assert_equal 0, c.call(&proc { |*args| args.size }), mode
      assert_equal 0, c.stats.failure_count, "#{mode}: a well-formed block counted as a failure"
    end
    scoped = B::Circuit.new(:ambient, policy, timeout: at(1))
    assert_instance_of DeadlineMachines::Scope, scoped.call { DeadlineMachines.current }
  end

  def test_coordinated_circuits_refuse_while_a_dependency_is_open
    database = B::Circuit.new(:database, policy)
    api = B::CoordinatedCircuit.new(:api, policy, depends_on: [:database])
    assert_equal :ok, api.call { :ok }
    database.force_open
    error = assert_raises(B::CircuitDependencyError) { api.call { :never } }
    assert_equal [:dependency, [:database]], [error.refusal, error.dependencies]
    refute_predicate api, :dependencies_healthy?
    assert_equal 0, api.breaker.outstanding, 'the core was never asked'
    fallback = B::CoordinatedCircuit.new(:fb, policy, depends_on: [database], fallback: :degraded)
    assert_equal :degraded, fallback.call { :never }
  end

  def test_cascading_circuits_trip_their_dependents
    weapons = B::Circuit.new(:weapons, policy)
    sensors = B::Circuit.new(:sensors, policy)
    tripped = []
    network = B::CascadingCircuit.new(:network, policy(failures: 1), cascades_to: %i[weapons sensors missing],
                                                                    on_cascade: ->(names) { tripped.concat(names) })
    assert_raises(IOError) { network.call { raise IOError } }
    assert_predicate weapons, :open?
    assert_predicate sensors, :open?
    assert_equal %i[weapons sensors], tripped
    assert_equal({ weapons: :open, sensors: :open, missing: :not_found }, network.dependent_status)
    assert_predicate network, :dependents_compromised?
    assert_equal %i[weapons sensors missing], network.cascade_info.dependent_circuits
    assert_match(/CASCADE/, network.summary)
    weapons.force_close
    assert_equal [:weapons], network.cascade_failure!
  end

  def test_circuit_groups_guard_members_by_their_dependencies
    group = B::CircuitGroup.new(:payments)
    group.circuit(:db, policy)
    group.circuit(:api, policy, depends_on: [:db])
    assert_equal :ok, group[:api].call { :ok }
    group[:db].force_open
    assert_raises(B::CircuitDependencyError) { group[:api].call { :never } }
    assert_equal({ db: :open, api: :closed }, group.status)
    assert_predicate group, :any_open?
    group.reset_all!
    assert_predicate group, :all_healthy?
    group.trip_all!
    assert_equal 'payments.db', group[:db].name
    refute group.dependencies_met?(:api)
  end

  # The refusal names the dependencies that are down, not the circuit called.
  def test_a_group_refusal_names_the_dependencies_that_are_down
    group = B::CircuitGroup.new(:ship)
    %i[power sensors comms].each { group.circuit(it, policy) }
    group.circuit(:helm, policy, depends_on: %i[power sensors comms])
    group[:power].force_open
    group[:comms].force_open
    error = assert_raises(B::CircuitDependencyError) { group[:helm].call { :never } }
    assert_equal ['ship.helm', :dependency, %i[power comms]], [error.circuit_name, error.refusal, error.dependencies]
    assert_equal "Circuit 'ship.helm' cannot be called: power, comms down", error.message
    assert_equal %i[power comms], group.dependencies_down(:helm)
    assert_equal 0, group[:helm].breaker.outstanding, 'the core was never asked'
  end

  # A guard that refuses with every dependency closed names no circuit.
  def test_a_group_guard_refusal_names_no_dependency
    group = B::CircuitGroup.new(:ship)
    group.circuit(:power, policy)
    group.circuit(:helm, policy, depends_on: [:power], guard_with: -> { false })
    error = assert_raises(B::CircuitDependencyError) { group[:helm].call { :never } }
    assert_equal [[], "Circuit 'ship.helm' cannot be called: its guard refused"], [error.dependencies, error.message]
    assert_empty group.dependencies_down(:helm)
  end

  def test_transitions_are_instrumented_and_logged
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/breaker_machines/) { |name, *| events << name }
    log = StringIO.new
    B.config.logger = Logger.new(log)
    B.setup_notifications
    c = B::Circuit.new(:loud, policy(failures: 1))
    assert_raises(IOError) { c.call { raise IOError } }
    assert_raises(B::CircuitOpenError) { c.call { :never } }
    assert_includes events, 'breaker_machines.opened'
    assert_includes events, 'breaker_machines.rejected'
    assert_match(/Circuit 'loud' opened/, log.string)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_the_console_drives_the_registry
    B::Circuit.new(:console_target, policy)
    output = StringIO.new
    B.console(input: StringIO.new("list\nopen console_target\nshow console_target\nevents console_target\n" \
                                  "stats\nreport\nreset console_target\nbogus\nhelp\ncleanup\nexit\n"), output:)
    text = output.string
    assert_match(/console_target\tclosed/, text)
    assert_match(/force_open console_target/, text)
    assert_match(/state: :open/, text)
    assert_match(/Unknown command: bogus/, text)
    assert_match(/Commands:/, text)
    assert_equal :exit, B::Console.new(output: StringIO.new).process('quit')
  end
end
