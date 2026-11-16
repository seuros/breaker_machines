# frozen_string_literal: true

require_relative 'test_helper'

class DslTest < Minitest::Test
  include BreakerHelpers

  POLICY = B::Policy.new(B::Threshold.new(1, nil, 0), 60 * SECOND, B::Recovery.new(30 * SECOND, 0.0, 1, 1), nil)

  class Service
    include BreakerMachines::DSL

    attr_reader :log

    def initialize = @log = []

    circuit_template :strict do
      policy POLICY
      handle IOError
    end

    circuit :api do
      policy POLICY
      handle IOError
      fallback { |error| "cached after #{error.class}" }
      on_open { log << :open }
    end

    def fetch = circuit(:api).call { raise IOError }
  end

  class Child < Service
    circuit :db do
      policy POLICY
    end
  end

  def teardown = B.registry.clear

  def test_definitions_build_one_circuit_per_instance_running_on_it
    service = Service.new
    assert_equal 'cached after IOError', service.fetch
    assert_equal [:open], service.log
    assert_same service.circuit(:api), service.circuit(:api)
    refute_same service.circuit(:api), Service.new.circuit(:api)
    assert_raises(KeyError) { service.circuit(:missing) }
    service.reset_all_circuits
    assert_predicate service.circuit(:api), :closed?
  end

  def test_definitions_and_templates_are_inherited
    assert_equal %i[api db], Child.circuits.keys
    assert_equal [:api], Service.circuits.keys
    assert_equal [:strict], Child.circuit_templates.keys
    assert_equal POLICY, Child.circuit(:db)[:policy]
  end

  def test_dynamic_circuits_from_templates_locally_or_globally
    service = Service.new
    local = service.dynamic_circuit(:inline, template: :strict) { fallback :spare }
    assert_equal :spare, local.call { raise IOError }
    assert_same local, service.circuit_instances[:inline]
    shared = service.dynamic_circuit(:shared, template: :strict, global: true)
    assert_same shared, Service.new.dynamic_circuit(:shared, template: :strict, global: true)
  end

  def test_a_definition_needs_a_policy
    assert_raises(ArgumentError) { Class.new { include BreakerMachines::DSL }.circuit(:x) { handle IOError } }
    assert_raises(ArgumentError) { B::DSL::CircuitBuilder.new.fallback }
  end
end

class DslFeaturesTest < Minitest::Test
  include BreakerHelpers

  POLICY = DslTest::POLICY

  class Ship
    include BreakerMachines::DSL

    attr_reader :alerts

    def initialize = @alerts = []

    circuit(:shields) { policy POLICY }

    cascade_circuit :reactor do
      policy POLICY
      cascades_to :shields
      emergency_protocol :red_alert
    end

    circuit :helm do
      policy POLICY
      depends_on :reactor
      storage BreakerMachines::Storage::Memory.new
      backends -> { raise IOError }, -> { :manual }
      timeout 1_000_000_000
    end

    def red_alert(tripped) = alerts << tripped
  end

  def teardown = B.registry.clear

  def test_definitions_build_coordinated_cascading_and_hedged_circuits
    ship = Ship.new
    ship.circuit(:shields)
    assert_instance_of B::CascadingCircuit, ship.circuit(:reactor)
    assert_instance_of B::CoordinatedCircuit, ship.circuit(:helm)
    assert_equal :manual, ship.circuit(:helm).call
    ship.circuit(:reactor).force_open
    assert_predicate ship.circuit(:shields), :open?
    assert_equal [[:shields]], ship.alerts
    assert_raises(B::CircuitDependencyError) { ship.circuit(:helm).call }
    assert_match(/Circuit 'helm'/, ship.circuits_summary[:helm])
  end
end
