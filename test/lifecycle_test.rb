# frozen_string_literal: true

require_relative 'test_helper'

# Model check: over random runs of every operation, the state_machines
# lifecycle and the native core never disagree, and every hook fired
# matches a transition the machine made.
class LifecycleTest < Minitest::Test
  include BreakerHelpers

  def teardown = B.registry.clear

  def test_the_lifecycle_never_diverges_from_the_core
    24.times do |seed|
      rng = Random.new(seed)
      clock = ManualClock.new
      fired = []
      hooks = %i[on_open on_close on_half_open].to_h { |hook| [hook, -> { fired << hook }] }
      circuit = B::Circuit.new(:model, policy(failures: rng.rand(1..3), successes: rng.rand(1..2),
                                              probes: rng.rand(1..2), limit: [nil, 1, 2].sample(random: rng)),
                               clock:, random: rng, **hooks)
      300.times do
        step(circuit, rng, clock)
        assert_equal circuit.breaker.state, circuit.state, "seed #{seed}"
      end
      refute_empty fired, "seed #{seed} fired no hook"
    end
  end

  private

  def attempt
    yield
  rescue IOError, B::CircuitRefusedError
    nil
  end

  def step(circuit, rng, clock)
    case rng.rand(9)
    when 0 then attempt { circuit.call { :ok } }
    when 1 then attempt { circuit.call { raise IOError } }
    when 2 then circuit.observe(%i[success failure].sample(random: rng), rng.rand(1000))
    when 3 then circuit.force_open
    when 4 then circuit.force_close
    when 5 then circuit.reset if rng.rand(6).zero?
    else clock.advance(at(rng.rand(12)))
    end
  end
end
