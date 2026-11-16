# frozen_string_literal: true

module BreakerMachines
  module Storage
    # Shares nothing and keeps nothing: every circuit stays alone.
    class Null
      def read_status(_name) = nil
      def write_status(_name, _record) = true
      def record_event(_name, _event) = true
      def event_log(_name, _limit) = []
      def clear(_name) = nil
      def clear_all = nil
    end
  end
end
