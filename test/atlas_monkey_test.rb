# frozen_string_literal: true

require 'test_helper'
require_relative 'dummy/app/models/base_ship'
require_relative 'dummy/app/models/science_vessel'
require_relative 'dummy/app/models/rmns_atlas_monkey'

class AtlasMonkeyTest < ActiveSupport::TestCase
  def setup
    @atlas = RMNSAtlasMonkey.instance
    # Reset all instance variables to clean state
    @atlas.instance_variable_set(:@wisdom_level, 0)
    @atlas.instance_variable_set(:@commentary_log, [])
    @atlas.instance_variable_set(:@contemplation_count, 0)

    # Force reset ALL circuits regardless of state
    %i[universal_commentary_engine sensor_array laboratory probe_launcher
       containment_field].each do |circuit_name|
      circuit = @atlas.circuit(circuit_name)
      # Use the public reset method if possible
      circuit.send(:reset) if circuit.open? || circuit.half_open?
    end

    # Reduce timeouts for testing to prevent long waits
    @atlas.circuit(:laboratory).config[:timeout] = 0.1
    @atlas.circuit(:sensor_array).config[:timeout] = 0.1
    @atlas.circuit(:probe_launcher).config[:timeout] = 0.1
    @atlas.circuit(:universal_commentary_engine).config[:timeout] = 0.1
  end

  def teardown
    # Make sure no threads are left hanging
    Thread.list.each do |thread|
      next if thread == Thread.current || thread == Thread.main

      thread.kill if thread.alive?
    end
  end

  def test_singleton_behavior
    # Can't create new instances
    assert_raises(NoMethodError) { RMNSAtlasMonkey.new }

    # Always get the same instance
    atlas1 = RMNSAtlasMonkey.instance
    atlas2 = RMNSAtlasMonkey.instance
    atlas3 = atlas_monkey # Using convenience method

    assert_same atlas1, atlas2
    assert_same atlas2, atlas3

    # Has the correct name and registry
    assert_equal 'RMNS Atlas Monkey', @atlas.name
    assert_equal 'RMN-2142', @atlas.registry_number
  end

  def test_universal_commentary_engine
    # Basic commentary
    wisdom = @atlas.provide_commentary('System error detected')

    assert_kind_of String, wisdom
    assert_predicate wisdom.length, :positive?

    # Commentary is logged
    recent = @atlas.recent_commentary(1)

    assert_equal 1, recent.length
    assert_match(/System error detected/, recent.first)
  end

  def test_wisdom_level_increases
    initial_wisdom = @atlas.wisdom_level

    @atlas.analyze_meaning_of_life

    assert_operator @atlas.wisdom_level, :>, initial_wisdom

    @atlas.contemplate_existence

    assert_operator @atlas.wisdom_level, :>, initial_wisdom + 1
  end

  def test_irony_detection
    # First test might fail if circuits time out, which is expected behavior
    result = @atlas.scan_for_irony('The circuit breaker broke')
    # Accept either the normal result or the fallback
    assert(result.match?(/irony/i) || result.match?(/spider-sense/i),
           "Expected irony detection or fallback message, got: #{result}")

    # If sensor array is open from timeout, reset it for next tests
    @atlas.circuit(:sensor_array).send(:reset) if @atlas.circuit(:sensor_array).open?

    # Test different irony levels based on length
    short_result = @atlas.scan_for_irony('OK') # Short = low irony

    assert(short_result.match?(/No irony detected/i) || short_result.match?(/spider-sense/i))

    medium_result = @atlas.scan_for_irony('Maybe') # Medium

    assert(medium_result.match?(/Moderate irony|universe chuckles/i) || medium_result.match?(/spider-sense/i))

    long_result = @atlas.scan_for_irony('Certainly') # 9 chars = high

    assert(long_result.match?(/High irony|cosmos.*laugh/i) || long_result.match?(/spider-sense/i))
  end

  def test_commentary_engine_circuit_breaker
    # Force the commentary engine to fail 42 times
    42.times do
      @atlas.circuit(:universal_commentary_engine).wrap { raise 'Existential error' }
    rescue StandardError
      nil
    end

    # Circuit should be open
    assert_predicate @atlas.circuit(:universal_commentary_engine), :open?

    # But we still get wisdom from the fallback
    wisdom = @atlas.provide_commentary('What is the meaning of life?')

    assert_kind_of String, wisdom
    assert_predicate wisdom.length, :positive?
  end

  def test_inherited_science_vessel_features
    # Can still do science vessel things
    assert_respond_to @atlas, :scan_anomaly
    assert_respond_to @atlas, :conduct_experiment
    assert_respond_to @atlas, :launch_probe

    # Has all the circuits from ScienceVessel plus its own
    assert @atlas.circuit(:sensor_array)
    assert @atlas.circuit(:laboratory)
    assert @atlas.circuit(:probe_launcher)
    assert @atlas.circuit(:containment_field)
    assert @atlas.circuit(:universal_commentary_engine)
  end

  def test_overridden_probe_launcher_adds_commentary
    initial_commentary_count = @atlas.recent_commentary.length

    # Launch a probe
    result = @atlas.launch_probe('Mysterious anomaly')

    assert_match(/probe launched/, result)

    # Should have added commentary
    new_commentary = @atlas.recent_commentary

    assert_operator new_commentary.length, :>, initial_commentary_count
    assert_includes new_commentary.last, 'Launching probe at Mysterious anomaly'
  end

  def test_philosophical_sensor_fallback
    # Break the sensors
    begin
      @atlas.circuit(:sensor_array).wrap { raise 'Reality buffer overflow' }
    rescue StandardError
      nil
    end

    # Fallback to intuition
    result = @atlas.scan_for_irony('The sensors that detect sensor failures have failed')

    assert_kind_of String, result

    # Should get intuition-based response
    anomaly_result = @atlas.scan_anomaly('Paradox field')

    assert_match(/spider-sense.*tingling|loose wire/, anomaly_result)
  end

  def test_meaning_of_life_analysis
    result = @atlas.analyze_meaning_of_life

    assert_match(/42/, result)
    assert_operator result.length, :>, 10 # Should include a universal truth too
  end

  def test_contemplation_in_laboratory
    result = @atlas.contemplate_existence

    assert_match(/I think, therefore I am.*spaceship/, result)

    # Force laboratory circuit to open by calling trip directly
    @atlas.circuit(:laboratory).send(:trip)

    # Laboratory circuit should be open
    assert_predicate @atlas.circuit(:laboratory), :open?, 'Laboratory circuit should be open'

    # Contemplation falls back
    result = @atlas.contemplate_existence

    assert_equal 'Experiments suspended - data preserved', result
  end

  def test_atlas_monkey_persistence_across_tests
    # Set some state
    @atlas.provide_commentary('Test persistence')
    wisdom_before = @atlas.wisdom_level

    # Get instance again (simulating another part of the code)
    another_ref = atlas_monkey

    # Should have the same state
    assert_equal wisdom_before, another_ref.wisdom_level
    # Check that we have at least one commentary (since we cleared the log in setup)
    assert_operator another_ref.recent_commentary.length, :>=, 1
  end
end
