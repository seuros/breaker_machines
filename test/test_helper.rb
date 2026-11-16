# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'breaker_machines'
require 'minitest/autorun'

module BreakerHelpers
  B = BreakerMachines
  SECOND = 1_000_000_000

  # `seconds` as Integer nanoseconds.
  def at(seconds) = seconds * SECOND

  # `failures` in a 60 s window open it; a 30 s cooldown with `jitter`;
  # `successes` probes close it, `probes` at a time; at most `limit` out.
  def policy(failures: 3, successes: 1, probes: 1, jitter: 0.0, limit: nil)
    B::Policy.new(B::Threshold.new(failures, nil, 0), at(60), B::Recovery.new(at(30), jitter, successes, probes),
                  limit)
  end

  # A breaker opened by `policy`'s failures at `now`.
  def opened(now = 0, **options)
    breaker = B::Breaker.new(policy(**options))
    breaker.policy.threshold.count.times do
      ticket = breaker.admit(now)
      breaker.complete(ticket, :failure, now, 0)
    end
    breaker
  end

  # Everything observable about a breaker.
  def snapshot(breaker)
    [breaker.state, breaker.latest, breaker.opened_at, breaker.retry_at, breaker.outstanding,
     breaker.half_open_attempts, breaker.half_open_successes, breaker.events(1000)]
  end

  # The call answers `refusal` and leaves `breaker` exactly as it was.
  def assert_refused(refusal, breaker)
    assert_includes B::REFUSALS, refusal
    before = snapshot(breaker)
    assert_equal refusal, yield
    assert_equal before, snapshot(breaker), "#{refusal} changed something"
  end

  # The call is honoured with `answer` and still changes nothing.
  def assert_repeat(answer, breaker)
    before = snapshot(breaker)
    assert_equal answer, yield
    assert_equal before, snapshot(breaker), "#{answer} changed something"
  end

  # Builds a value past `initialize`: Marshal.load skips it. `from` and `to`
  # are the marshalled bytes of one field, before and after.
  def forge(value, from, to)
    bytes = Marshal.dump(value)
    raise ArgumentError, 'field not found' unless bytes.include?(from)

    Marshal.load(bytes.sub(from, to)) # rubocop:disable Security/MarshalLoad
  end
end

# A clock a test moves by hand.
class ManualClock
  attr_reader :now

  def initialize(now = 0) = @now = now
  def advance(by) = @now += by
  def call = @now
end
