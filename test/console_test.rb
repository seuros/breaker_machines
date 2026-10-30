# frozen_string_literal: true

require 'test_helper'
require 'breaker_machines/console'

class ConsoleTest < ActiveSupport::TestCase
  test 'shows event times as wall-clock dates' do
    circuit = BreakerMachines::Circuit.new(:console_events, storage: BreakerMachines::Storage::Memory.new)
    circuit.call { :ok }

    output, = capture_io { BreakerMachines::Console.new.send(:show_events, 'console_events', 10) }

    assert_includes output, Time.now.strftime('%Y-%m-%d')
    refute_includes output, '1970-'
  end
end
