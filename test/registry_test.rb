# frozen_string_literal: true

require_relative 'test_helper'

class RegistryTest < Minitest::Test
  include BreakerHelpers

  def setup = B.registry.clear
  def teardown = B.registry.clear

  def test_circuits_register_unless_told_not_to
    a = B::Circuit.new(:a, policy)
    B::Circuit.new(:hidden, policy, auto_register: false)
    assert_equal [a], B.registry.all_circuits
    assert_same a, B.registry.find(:a)
    assert B.registry.force_open(:a)
    assert_predicate a, :open?
    assert B.registry.force_close(:a)
    assert B.registry.reset(:a)
    refute B.registry.reset(:missing)
    assert_equal({ total: 1, by_state: { closed: 1 }, by_name: { a: 1 } }, B.registry.stats_summary)
    assert_equal [:a], B.registry.detailed_report.map { |report| report[:name] }
    B.registry.unregister(a)
    assert_empty B.registry.all_circuits
    assert_equal 0, B.registry.cleanup_dead_references
  end

  def test_dynamic_circuits_are_shared_by_name_until_removed_or_stale
    owner = Object.new
    first = B.registry.get_or_create_dynamic_circuit(:shared, owner, policy, exceptions: [IOError])
    assert_same first, B.registry.get_or_create_dynamic_circuit(:shared, Object.new, policy)
    assert_equal [:shared], B.registry.dynamic_circuit_names
    assert_equal 0, B.registry.cleanup_stale_dynamic_circuits
    assert_equal 1, B.registry.cleanup_stale_dynamic_circuits(-1)
    B.registry.get_or_create_dynamic_circuit(:shared, owner, policy)
    assert B.registry.remove_dynamic_circuit(:shared)
    refute B.registry.remove_dynamic_circuit(:shared)
  end
end
