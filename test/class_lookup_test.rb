# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'rbconfig'

# The classes of the values the extension wraps (Breaker, Ticket) are fixed
# when it loads. Nothing a caller does later, redefining a constant or
# `Object.const_get`, reaches a value being built or read. Each case runs in
# a fresh process: the class is fixed once per process, at load.
class ClassLookupTest < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  PRELUDE = <<~RUBY
    require 'breaker_machines'
    B = BreakerMachines
    policy = B::Policy.new(B::Threshold.new(1, nil, 0), 60, B::Recovery.new(30, 0.0, 1, 1), nil)
  RUBY

  # Runs `body` after PRELUDE in a new Ruby; answers its last line of output.
  def isolated(body)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', LIB, '-e', PRELUDE + body)
    assert status.success?, "exited #{status.exitstatus}: #{err}"
    out.lines.last&.chomp
  end

  # Bug: a Breaker constant redefined before the first breaker was built
  # made it an instance of the new class, and every method on it raised.
  def test_a_redefined_breaker_constant_does_not_change_the_breaker_class
    assert_equal 'true closed', isolated(<<~RUBY)
      original = B::Breaker
      B.send(:remove_const, :Breaker)
      B.const_set(:Breaker, Class.new)
      breaker = original.new(policy)
      puts [breaker.instance_of?(original), breaker.state].join(' ')
    RUBY
  end

  # A ticket admitted after its constant was redefined is still a Ticket the
  # breaker takes back.
  def test_a_redefined_ticket_constant_does_not_change_the_ticket_class
    assert_equal 'true released 0', isolated(<<~RUBY)
      breaker = B::Breaker.new(policy)
      original = B::Ticket
      B.send(:remove_const, :Ticket)
      B.const_set(:Ticket, Class.new)
      ticket = breaker.admit(0)
      puts [ticket.instance_of?(original), breaker.abandon(ticket), breaker.outstanding].join(' ')
    RUBY
  end

  # Bug: building or reading the first breaker ran `Object.const_get`, so a
  # redefined one could freeze the breaker mid-call. No Ruby runs between
  # the checks and the core call now.
  def test_building_and_using_a_breaker_runs_no_const_get
    assert_equal '0 false 1 Ticket', isolated(<<~RUBY)
      hits = 0
      breaker = nil
      Object.define_singleton_method(:const_get) do |*args|
        hits += 1
        breaker&.freeze
        super(*args)
      end
      breaker = B::Breaker.new(policy)
      ticket = breaker.admit(0)
      puts [hits, breaker.frozen?, breaker.outstanding, ticket.class.name.split('::').last].join(' ')
    RUBY
  end

  # Bug: a redefined `Object.const_get` that raised hit an `unwrap` in the
  # extension: an uncatchable fatal, and the process exited.
  def test_a_raising_const_get_does_not_kill_the_process
    assert_equal 'closed released', isolated(<<~RUBY)
      Object.define_singleton_method(:const_get) { |*| raise IOError, 'lookup ran mid-call' }
      breaker = B::Breaker.new(policy)
      ticket = breaker.admit(0)
      puts [breaker.state, breaker.abandon(ticket)].join(' ')
    RUBY
  end
end
