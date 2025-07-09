# BreakerMachines Diagrams

This document contains all the technical diagrams and visualizations for BreakerMachines. Because sometimes you need to see the chaos to understand it.

## The Circuit Breaker State Machine

The fundamental state machine that keeps your services from melting down:

```mermaid
stateDiagram-v2
    [*] --> closed: Birth of Hope
    closed --> open: Too Many Failures (Reality Check)
    open --> half_open: Time Heals (But Not Your Kubernetes Cluster)
    half_open --> closed: Service Restored (Temporary Victory)
    half_open --> open: Still Broken (Welcome to Production)

    note right of closed: All services operational\n(Don't get comfortable)
    note right of open: Circuit broken\n(At least it's honest)
    note right of half_open: Testing the waters\n(Like deploying on Friday)
```

## The Retry Death Spiral

What happens when you think retry logic equals resilience:

```mermaid
graph LR
    A[Your Service] -->|Timeout| B[Retry]
    B -->|Timeout| C[Retry Harder]
    C -->|Timeout| D[Retry With Feeling]
    D -->|Dies| E[Takes Down Redis]
    E --> F[PostgreSQL Follows]
    F --> G[Ractor Cores Meltdown]
    G --> H[🔥 Everything Is Fire 🔥]
```

## Cascade Failure Visualization

The domino effect that turns one small failure into a complete system meltdown:

```mermaid
graph TD
    A[Service A Fails] --> B[Service B Overwhelmed]
    B --> C[Service C Drowns in Retries]
    C --> D[Service D Connection Pool Exhausted]
    D --> E[Entire System Collapse]

    style A fill:#ff6b6b
    style E fill:#c92a2a
```

## Hedged Request Flow

How BreakerMachines implements hedged requests to reduce latency:

```mermaid
sequenceDiagram
    participant C as Client
    participant CB as Circuit Breaker
    participant S1 as Primary Service
    participant S2 as Secondary Service

    C->>CB: Request
    CB->>S1: Try Primary
    Note over CB: Wait 100ms
    CB->>S2: Hedged Request
    S2-->>CB: Fast Response
    CB-->>C: Return First Success
    Note over S1: Still processing...
```

## Bulkhead Pattern

Isolating failures to prevent total system compromise:

```mermaid
graph TB
    subgraph "Without Bulkheading"
        A1[Service Pool] --> B1[One Bad Request]
        B1 --> C1[🔥 All Threads Blocked 🔥]
    end

    subgraph "With Bulkheading"
        A2[Service Pool] --> B2[Isolated Compartments]
        B2 --> C2[Limited Blast Radius]
        B2 --> D2[Other Requests Continue]
    end
```

## Production Reality Check

What your architecture looks like vs what actually happens:

```mermaid
graph LR
    subgraph "The Plan"
        PA[API Gateway] --> PB[Load Balancer]
        PB --> PC[Service Mesh]
        PC --> PD[Microservices]
    end

    subgraph "Reality at 3 AM"
        RA[Overloaded Gateway] -.-> RB[Dead LB]
        RB -.-> RC[Service Mesh on Fire]
        RC -.-> RD[Cascading Failures]
        RD --> RE[Your Phone Ringing]
    end
```

---

*Remember: These diagrams aren't just technical documentation—they're warnings from the future.*