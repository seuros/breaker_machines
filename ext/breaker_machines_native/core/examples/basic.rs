//! Basic circuit breaker usage example

use breaker_machines::CircuitBreaker;

fn main() {
    println!("=== Circuit Breaker Basic Example ===\n");

    // Create a circuit with builder API
    let mut circuit = CircuitBreaker::builder("payment_api")
        .failure_threshold(3)
        .failure_window_secs(10.0)
        .half_open_timeout_secs(5.0)
        .success_threshold(2)
        .on_open(|name| println!("🔴 Circuit '{}' opened!", name))
        .on_close(|name| println!("🟢 Circuit '{}' closed!", name))
        .on_half_open(|name| println!("🟡 Circuit '{}' half-open, testing...", name))
        .build();

    println!("Initial state: {}\n", circuit.state_name());

    // Simulate successful calls
    println!("--- Successful calls ---");
    for i in 1..=2 {
        match circuit.call(move || Ok::<_, String>(format!("Payment {}", i))) {
            Ok(result) => println!("✓ {}", result),
            Err(e) => println!("✗ Error: {}", e),
        }
    }
    println!("State: {}\n", circuit.state_name());

    // Simulate failures
    println!("--- Triggering failures ---");
    for i in 1..=3 {
        match circuit.call(move || Err::<String, _>(format!("Payment failed {}", i))) {
            Ok(_) => println!("✓ Success"),
            Err(e) => println!("✗ {}", e),
        }
    }
    println!("State: {} (circuit opened)\n", circuit.state_name());

    // Try calling while open
    println!("--- Attempting call while open ---");
    match circuit.call(|| Ok::<_, String>("Should be rejected")) {
        Ok(_) => println!("✓ Success"),
        Err(e) => println!("✗ {}", e),
    }
    println!();

    // Reset and demonstrate recovery
    println!("--- Resetting circuit ---");
    circuit.reset();
    println!("State after reset: {}\n", circuit.state_name());

    // Successful calls after reset
    println!("--- Calls after reset ---");
    match circuit.call(|| Ok::<_, String>("Payment successful")) {
        Ok(result) => println!("✓ {}", result),
        Err(e) => println!("✗ {}", e),
    }
    println!("State: {}", circuit.state_name());
}
