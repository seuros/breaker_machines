# frozen_string_literal: true

require 'test_helper'

class CircuitProtectionTest < ActiveSupport::TestCase
  Client = Struct.new(:error, :calls, keyword_init: true) do
    def request(path = '/health', headers: {})
      self.calls += 1
      raise error if error

      block_given? ? yield(path, headers) : self
    end

    def get(...)
      request(...)
    end

    def options
      :settings
    end
  end

  def setup
    @circuit = BreakerMachines::Circuit.new(:client, failure_threshold: 1, exceptions: [IOError])
    @client = Client.new(calls: 0)
    @protected = @circuit.protect(@client, methods: %i[request get])
  end

  def test_forwards_arguments_keywords_blocks_and_the_result
    result = @protected.request('/pods', headers: { accept: 'json' }) { |path, headers| [path, headers] }

    assert_equal ['/pods', { accept: 'json' }], result
  end

  def test_internal_calls_are_counted_once
    @protected.get

    assert_equal 1, @circuit.storage.success_count(:client, 60)
  end

  def test_wrappers_share_the_circuit_and_reject_calls_before_reaching_the_client
    other = @circuit.protect(@client, methods: [:request])
    @client.error = IOError.new('Offline')

    assert_same @client.error, assert_raises(IOError) { @protected.get }
    assert_raises(BreakerMachines::CircuitOpenError) { other.request }
    assert_equal 1, @client.calls
  end

  def test_unhandled_errors_do_not_open_the_circuit
    @client.error = ArgumentError.new('Invalid request')

    assert_raises(ArgumentError) { @protected.request }
    assert_predicate @circuit, :closed?
  end

  def test_uses_the_configured_fallback
    circuit = BreakerMachines::Circuit.new(:fallback, fallback: ->(_) { :unavailable })
    @client.error = IOError.new('Offline')

    assert_equal :unavailable, circuit.protect(@client, methods: [:request]).request
  end

  def test_other_methods_remain_available_while_the_circuit_is_open
    @circuit.trip!

    assert_respond_to @protected, :options
    assert_equal :settings, @protected.options
    assert_equal 0, @circuit.storage.success_count(:client, 60)
  end

  def test_does_not_modify_the_original_client
    @circuit.trip!

    assert_same @client, @client.request
  end

  def test_does_not_wrap_returned_objects
    assert_same @client, @protected.request
  end

  def test_rejects_an_empty_method_list
    assert_raises(ArgumentError) { @circuit.protect(@client, methods: []) }
  end

  def test_rejects_unknown_or_private_methods
    %i[missing initialize].each do |name|
      assert_raises(ArgumentError) { @circuit.protect(@client, methods: [name]) }
    end
  end

  def test_works_with_native_circuits
    skip 'Native extension not available' unless BreakerMachines.native_available?

    circuit = BreakerMachines::Circuit::Native.new('native_client', failure_threshold: 1)
    protected_client = circuit.protect(@client, methods: [:request])
    @client.error = IOError.new('Offline')

    assert_raises(IOError) { protected_client.request }
    assert_raises(BreakerMachines::CircuitOpenError) { protected_client.request }
    assert_equal 1, @client.calls
  end
end
