# BreakerMachines RBS Type Signatures

This directory contains RBS (Ruby type signatures) for the BreakerMachines gem.

## Structure

- `breaker_machines.rbs` - Main module and configuration
- `breaker_machines/` - Type signatures for all classes and modules
  - `circuit.rbs` - Circuit class and its modules
  - `errors.rbs` - Error classes
  - `storage.rbs` - Storage backends
  - `dsl.rbs` - DSL module for including in classes
  - `registry.rbs` - Global circuit registry
  - `console.rbs` - Interactive console
  - `types.rbs` - Common type aliases
  - `interfaces.rbs` - Interface definitions

## Usage

To use these type signatures in your project:

1. Add to your `Steepfile`:
   ```ruby
   target :app do
     signature "sig"
     check "lib"

     library "breaker_machines"
   end
   ```

2. Or with RBS directly:
   ```bash
   rbs validate
   ```

## Type Checking Examples

### Basic Circuit Usage
```ruby
circuit = BreakerMachines::Circuit.new("api",
  failure_threshold: 5,
  reset_timeout: 30
)

result = circuit.call { api.fetch_data }
```

### DSL Usage
```ruby
class MyService
  include BreakerMachines::DSL

  circuit :database do
    threshold failures: 10, within: 60
    reset_after 120
    fallback { [] }
  end
end
```

## Key Types

- `circuit_state` - `:open | :closed | :half_open`
- `storage_backend` - `:memory | :bucket_memory | :null | :redis`
- `circuit_options` - Configuration hash for circuits
- `event_record` - Structure for logged events

## Interfaces

The type signatures define several interfaces:
- `_StorageBackend` - For custom storage implementations
- `_MetricsRecorder` - For custom metrics recording
- `_CircuitLike` - For circuit-compatible objects