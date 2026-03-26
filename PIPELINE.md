# Exhaust Pipeline

*Last updated: 2026-03-25*

This diagram shows what happens when you run `#exhaust` with a generator and a property. Exhaust first tries to systematically cover the generator's parameter space using structured coverage. If the generator isn't analyzable, or coverage doesn't find a failure, it falls back to random sampling. When a failure is found, the Bonsai reducer shrinks it through alternating phases of structural and value minimization, guided by an adaptive scheduler that skips unproductive phases and re-checks when conditions change. The result is a minimal counterexample reported back to the test.

```mermaid
flowchart TD
    A["#exhaust { gen, property }"] --> C{"Generator analyzable? (no branching, no deep bind chains)"}

    C -->|"Yes"| D["Analyze generator: run generator, walk the choice tree to extract independent parameters"]
    C -->|"No"| H

    D --> E{"Domain size?"}
    E -->|"All params have 256 values or fewer"| F["Finite domain: enumerate all values per parameter"]
    E -->|"Some large domains"| G["Boundary domain: synthesize interesting boundary values for each parameter by type"]

    F --> COV["Structured coverage: pull-based density algorithm, lazily emit rows, test property (captures value + choice tree per row)"]
    G --> COV

    COV --> COV_R{"Coverage result?"}
    COV_R -->|"Failure found"| COV_REFLECT
    COV_R -->|"Exhaustive pass"| PASS["Property passed (entire space tested)"]
    COV_R -->|"Partial or not applicable"| H

    COV_REFLECT["Best-effort 'reflect' to enrich coverage tree with unselected branches needed by reducer"] --> SCHED

    H["Random sampling: PRNG-driven generation (captures value + choice tree per iteration)"] --> I{"Property fails?"}
    I -->|"No, budget exhausted"| PASS2["Property passed"]
    I -->|"Yes"| SCHED

    subgraph REDUCE ["Bonsai Reducer: receives failing value + choice tree"]
        direction TB
        SCHED["Schedule reduction"] --> PROJ

        PROJ["Phase 0, free coordinate projection: zero out all positions that no structural decision depends on"] --> BD

        subgraph CYCLE ["Cycle loop, until stall budget exhausted"]
            direction TB
            BD{"Structural work available and prior cycle productive?"} -->|"Yes"| BD_RUN
            BD -->|"No, skip"| FD

            BD_RUN["Phase 1, structural minimization: promote and reorder branches, delete contiguous spans, reduce bind-inner values"] --> FD

            FD["Phase 2, value minimization: coordinate descent over dependency graph, binary search, linear scan, zero-value encoders, shortlex sibling reordering"] --> EXP_GATE

            EXP_GATE{"Prior cycle edges not all exhausted clean, and no earlier phase accepted?"} -->|"Yes"| EXP
            EXP_GATE -->|"No, skip"| RLX_GATE

            EXP["Phase 3, exploration: compose multi-step reductions, escape local minima"] --> RLX_GATE

            RLX_GATE{"Coupled coordinates detected, or no earlier phase accepted?"} -->|"Yes"| RLX
            RLX_GATE -->|"No, skip"| PROBE

            RLX["Phase 4, relax-round: temporarily worsen then re-descend, escape coupled dependencies"] --> PROBE

            PROBE{"Phase 1 was skipped and deletion targets exist?"} -->|"Yes"| PROBE_RUN
            PROBE -->|"No"| STALL

            PROBE_RUN["Deletion probe: lightweight structural pass to check if value changes enabled new deletions"] --> STALL

            STALL{"Improved? (shortlex order)"}
            STALL -->|"Yes, reset stall budget"| BD
            STALL -->|"No, decrement"| STALL2{"Stall budget exhausted?"}
            STALL2 -->|"No"| BD
            STALL2 -->|"Yes"| DONE
        end

        DONE["Human-readable ordering: reorder elements into natural numeric order"]
    end

    DONE --> REPORT

    REPORT["Render failure: shrunk counterexample, diff from original, replay seed, invocation count"] --> ISSUE["Report failure back to the test, return minimal counterexample"]

    style REDUCE fill:#e8eaf6,stroke:#3949ab,color:#1a237e
    style CYCLE fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
    style PASS fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
    style PASS2 fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
    style ISSUE fill:#fce4ec,stroke:#c62828,color:#b71c1c
```
