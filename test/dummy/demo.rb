#!/usr/bin/env ruby
# frozen_string_literal: true

# Run with: ruby demo.rb

require 'net/http'
require 'json'
require 'colorize' # gem install colorize for colors (optional)

BASE_URL = 'http://localhost:3000'

def colorize_available?
  defined?(Colorize)
rescue StandardError
  false
end

def green(text)
  colorize_available? ? text.green : text
end

def red(text)
  colorize_available? ? text.red : text
end

def yellow(text)
  colorize_available? ? text.yellow : text
end

def get_json(path)
  uri = URI("#{BASE_URL}#{path}")
  response = Net::HTTP.get_response(uri)
  JSON.parse(response.body)
end

def post(path)
  uri = URI("#{BASE_URL}#{path}")
  Net::HTTP.post(uri, '')
end

puts 'BreakerMachines Demo'
puts '==================='
puts

# Reset circuit to start fresh
puts 'Resetting circuit...'
post('/circuits/weather_api/reset')
puts green('✓ Circuit reset')
puts

# Show normal operation
puts '1. Normal Operation (Circuit Closed)'
puts '------------------------------------'
3.times do |i|
  data = get_json('/weather')
  puts "Request #{i + 1}: Temperature: #{data['temperature']}°F, Source: #{green(data['source'])}"
  sleep 0.5
end
puts

# Trigger failures
puts '2. Triggering Failures'
puts '----------------------'
3.times do |i|
  data = get_json('/force_failure')
  puts "Failure #{i + 1}: #{red(data['error'])}, Circuit state: #{yellow(data['circuit_state'])}"
  sleep 0.5
end
puts

# Show circuit open behavior
puts '3. Circuit Open - Using Fallback'
puts '--------------------------------'
3.times do |i|
  data = get_json('/weather')
  puts "Request #{i + 1}: Temperature: #{data['temperature']}°F, Source: #{yellow(data['source'])}"
  puts "  └─ Error: #{red(data['error'])}" if data['error']
  sleep 0.5
end
puts

# Show circuit status
puts '4. Circuit Status'
puts '-----------------'
circuits = get_json('/circuits')
circuit = circuits['circuits'].first
puts "Name: #{circuit['name']}"
puts "State: #{red(circuit['state'])}"
puts "Failures: #{circuit['failure_count']}"
puts 'Config:'
puts "  - Failure threshold: #{circuit['config']['failure_threshold']}"
puts "  - Window: #{circuit['config']['failure_window']}s"
puts "  - Reset timeout: #{circuit['config']['reset_timeout']}s"
puts

# Wait and show half-open
puts '5. Waiting for Circuit to Half-Open...'
puts '-------------------------------------'
puts 'Waiting 30 seconds for reset timeout...'
30.times do |i|
  print "\r#{30 - i} seconds remaining... "
  sleep 1
end
puts "\n"

# Try again - should attempt real call
puts '6. Circuit Half-Open - Testing Recovery'
puts '--------------------------------------'
data = get_json('/weather')
if data['source'] == 'live'
  puts green("✓ Circuit recovered! Source: #{data['source']}")
else
  puts yellow("Circuit still using fallback: #{data['source']}")
end

puts "\nDemo complete!"
