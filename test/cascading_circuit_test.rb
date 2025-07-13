# frozen_string_literal: true

require 'test_helper'

class CascadingCircuitTest < ActiveSupport::TestCase
  def self.create_spaceship_class
    Class.new do
      include BreakerMachines::DSL

      cascade_circuit :main_power do
        threshold failures: 3, within: 60.seconds
        cascades_to :life_support, :navigation, :weapons
        emergency_protocol :emergency_shutdown
      end

      circuit :life_support do
        threshold failures: 5, within: 60.seconds
      end

      circuit :navigation do
        threshold failures: 5, within: 60.seconds
      end

      circuit :weapons do
        threshold failures: 5, within: 60.seconds
      end

      attr_reader :cascade_log

      def initialize
        super
        @cascade_log = []
        @emergency_executed = false
        @affected_circuits = nil
      end

      def emergency_shutdown(affected_circuits)
        @emergency_executed = true
        @affected_circuits = affected_circuits
        @cascade_log << affected_circuits if affected_circuits && !affected_circuits.empty?
      end

      def emergency_executed?
        @emergency_executed
      end

      def affected_circuits
        @affected_circuits
      end

      def trigger_power_failure
        3.times do
          circuit(:main_power).call { raise 'Power failure!' }
        rescue StandardError
          # Expected
        end
      end
    end
  end

  setup do
    # Clear any existing circuits from registry
    BreakerMachines.registry.clear if BreakerMachines.registry.respond_to?(:clear)

    # Create a fresh test class for each test to avoid state pollution
    spaceship_class = self.class.create_spaceship_class
    @ship = spaceship_class.new
  end

  teardown do
    # Reset all circuits to ensure test isolation
    if @ship
      @ship.reset_all_circuits if @ship.respond_to?(:reset_all_circuits)
      # Clear instance circuit cache
      @ship.instance_variable_set(:@circuit_instances, nil) if @ship.instance_variable_defined?(:@circuit_instances)
    end
    # Clear any class-level circuit definitions that might pollute tests
    if @ship && @ship.class.instance_variable_defined?(:@circuits)
      @ship.class.instance_variable_set(:@circuits, nil)
    end
    # Clear registry
    BreakerMachines.registry.clear if BreakerMachines.registry.respond_to?(:clear)
  end

  test 'cascading circuit inherits from base circuit' do
    assert_kind_of BreakerMachines::Circuit, @ship.circuit(:main_power)
    assert_instance_of BreakerMachines::CascadingCircuit, @ship.circuit(:main_power)
  end

  test 'dependent circuits are tripped when parent opens' do
    # Initially all circuits should be closed
    assert @ship.circuit(:main_power).closed?
    assert @ship.circuit(:life_support).closed?
    assert @ship.circuit(:navigation).closed?
    assert @ship.circuit(:weapons).closed?


    # Trigger main power failures
    @ship.trigger_power_failure

    # Main power should be open
    assert @ship.circuit(:main_power).open?

    # All dependent circuits should also be open
    assert @ship.circuit(:life_support).open?
    assert @ship.circuit(:navigation).open?
    assert @ship.circuit(:weapons).open?
  end

  test 'emergency protocol is executed on cascade' do
    refute @ship.emergency_executed?

    @ship.trigger_power_failure

    assert @ship.emergency_executed?
    assert_equal [:life_support, :navigation, :weapons], @ship.affected_circuits
  end

  test 'on_cascade tracking via emergency protocol' do
    assert_empty @ship.cascade_log

    @ship.trigger_power_failure

    # The emergency protocol adds to cascade_log
    assert_equal [[:life_support, :navigation, :weapons]], @ship.cascade_log
  end

  test 'cascading only affects specified circuits' do
    # Main and dependent circuits should be open after trigger
    @ship.trigger_power_failure

    assert @ship.circuit(:main_power).open?
    assert @ship.circuit(:life_support).open?
    assert @ship.circuit(:navigation).open?
    assert @ship.circuit(:weapons).open?

    # Create a new ship instance with auxiliary power circuit
    ship2_class = self.class.create_spaceship_class
    ship2_class.circuit :auxiliary_power do
      threshold failures: 5, within: 60.seconds
    end
    ship2 = ship2_class.new

    # Verify auxiliary power is not affected by the first ship's cascade
    assert ship2.circuit(:auxiliary_power).closed?
  end

  test 'cascading circuit configuration' do
    config = @ship.class.circuits[:main_power]
    assert_equal :cascading, config[:circuit_type]
    assert_equal [:life_support, :navigation, :weapons], config[:cascades_to]
    assert_equal :emergency_shutdown, config[:emergency_protocol]
  end
end
