# frozen_string_literal: true

require 'delegate'

module BreakerMachines
  class Circuit
    class Proxy < SimpleDelegator
      def initialize(object, circuit:, methods:)
        raise ArgumentError, 'methods must not be empty' if methods.empty?

        methods.each do |name|
          raise ArgumentError, "Unknown public method: #{name}" unless object.respond_to?(name)
        end

        super(object)

        methods.each do |name|
          define_singleton_method(name) do |*args, **kwargs, &block|
            circuit.call { __getobj__.public_send(name, *args, **kwargs, &block) }
          end
        end
      end
    end
  end
end
