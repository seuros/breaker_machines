# frozen_string_literal: true

require 'test_helper'

class SpaceshipTest < ActiveSupport::TestCase
  def setup
    @ship = Spaceship.new('USS Enterprise')
    # Reset all circuits to ensure clean state
    @ship.circuit(:warp_drive).send(:reset) if @ship.circuit(:warp_drive).send(:open?)
    @ship.circuit(:fusion_reactor).send(:reset) if @ship.circuit(:fusion_reactor).send(:open?)
    @ship.circuit(:navigation_computer).send(:reset) if @ship.circuit(:navigation_computer).send(:open?)
  end

  def test_successful_warp_engagement
    result = @ship.engage_warp('Alpha Centauri')

    assert_equal 'engaged', result[:status]
    assert_equal 'Alpha Centauri', result[:destination]
    assert_equal 'warp_9', result[:speed]
  end

  def test_warp_drive_circuit_opens_after_failures
    # Simulate warp drive failures
    SpaceflightSystems::WarpDrive.stub :engage, ->(_) { raise SpaceflightSystems::WarpDriveError } do
      # First 3 calls should fail and count towards threshold
      3.times do
        assert_equal({ status: 'emergency_mode', speed: 'impulse_only' }, @ship.engage_warp('Vulcan'))
      end

      # Circuit should now be open
      assert_predicate @ship.circuit(:warp_drive), :open?

      # Verify captain's log
      assert(@ship.captain_log.any? { |log| log.include?('WARNING: Warp drive circuit breaker opened!') })
      assert(@ship.captain_log.any? { |log| log.include?('Engaging emergency thrusters') })
    end
  end

  def test_fusion_reactor_fallback
    SpaceflightSystems::FusionReactor.stub :ignite, ->(_) { raise SpaceflightSystems::ReactorOverloadError } do
      result = @ship.power_up_reactor(100)

      assert_equal 'auxiliary', result[:status]
      assert_equal 40, result[:power_output]
      assert(@ship.captain_log.any? { |log| log.include?('Switching to auxiliary power') })
    end
  end

  def test_circuit_recovery_after_reset_timeout
    warp_circuit = @ship.circuit(:warp_drive)

    # Force circuit to open
    SpaceflightSystems::WarpDrive.stub :engage, ->(_) { raise SpaceflightSystems::WarpDriveError } do
      3.times { @ship.engage_warp('Earth') }
    end

    assert_predicate warp_circuit, :open?

    # Force the circuit to think the reset timeout has elapsed
    # by setting opened_at to a monotonic time in the past
    # With 25% jitter, max timeout is 30 * 1.25 = 37.5 seconds
    opened_at = warp_circuit.instance_variable_get(:@opened_at)
    opened_at.value = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 40 # 40 seconds ago (well past any jitter)

    # Stub successful call for recovery
    SpaceflightSystems::WarpDrive.stub :engage, lambda { |dest|
      { status: 'engaged', destination: dest, speed: 'warp_9' }
    } do
      # Circuit should attempt recovery and succeed
      result = @ship.engage_warp('Earth')

      assert_equal 'engaged', result[:status]

      # Circuit should be closed again
      assert_predicate warp_circuit, :closed?
    end
  end

  def test_navigation_computer_timeout
    # Since forceful timeouts are not implemented for safety,
    # the operation will complete normally
    # In production, use library-specific timeouts
    slow_navigation = lambda do |_|
      { route: 'calculated', distance: '100 parsecs', eta: '10 hours' }
    end

    SpaceflightSystems::NavigationComputer.stub :calculate_route, slow_navigation do
      result = @ship.calculate_route([42.3, -17.9, 88.1])

      # Operation completes normally
      assert_equal 'calculated', result[:route]
      assert_equal '100 parsecs', result[:distance]
    end
  end

  def test_multiple_circuit_breakers_independence
    # Open warp drive circuit
    SpaceflightSystems::WarpDrive.stub :engage, ->(_) { raise SpaceflightSystems::WarpDriveError } do
      3.times { @ship.engage_warp('Mars') }
    end

    assert_predicate @ship.circuit(:warp_drive), :open?
    assert_predicate @ship.circuit(:fusion_reactor), :closed?
    assert_predicate @ship.circuit(:navigation_computer), :closed?

    # Other systems should still work normally
    result = @ship.power_up_reactor(80)

    assert_equal 'online', result[:status]

    result = @ship.calculate_route([1.1, 2.2, 3.3])

    assert_equal 'calculated', result[:route]
  end

  def test_half_open_state_behavior
    reactor_circuit = @ship.circuit(:fusion_reactor)

    # Open the circuit
    SpaceflightSystems::FusionReactor.stub :ignite, ->(_) { raise SpaceflightSystems::ReactorOverloadError } do
      2.times { @ship.power_up_reactor(100) }
    end

    assert_predicate reactor_circuit, :open?

    # Force the circuit to think the reset timeout has elapsed
    # With 25% jitter, max timeout is 45 * 1.25 = 56.25 seconds
    opened_at = reactor_circuit.instance_variable_get(:@opened_at)
    opened_at.value = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 60 # 60 seconds ago (well past any jitter)

    # Next call should trigger half-open state
    SpaceflightSystems::FusionReactor.stub :ignite, ->(level) { { status: 'online', power_output: level } } do
      result = @ship.power_up_reactor(50)

      # Should succeed and close circuit
      assert_equal 'online', result[:status]
      assert_predicate reactor_circuit, :closed?
      assert(@ship.captain_log.any? { |log| log.include?('Attempting reactor restart...') })
    end
  end
end
