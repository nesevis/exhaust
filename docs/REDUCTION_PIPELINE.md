# Reducer Pipeline

*Last updated: 2026-05-14*

When Exhaust finds a failing test case, the reducer "shrinks" it down it to a minimal counterexample. It builds a graph from the choice tree — a structural map of every decision the generator made — then tries operations that make the counterexample smaller or simpler while keeping the property failing. Structural operations (delete elements, collapse recursion levels, swap branches) compete with value operations (binary search toward zero, redistribute between coupled parameters) in a shared priority queue. The highest-priority operation wins at each step.

The reducer runs in cycles. Each cycle pulls operations from the graph until all sources are exhausted, then checks whether anything improved. If values have all converged and no structural progress was made, it exits early. Otherwise it decrements a stall budget and tries again.

```mermaid
flowchart TD
    ENTRY["Receive failing value + choice tree"] --> BUILD
    BUILD["Build a graph from the choice tree"] --> PICK

    PICK["Pick the highest-priority operation from the graph"] --> TRY
    TRY["Try it: build a candidate, replay through the generator, check the property"] --> ACCEPTED

    ACCEPTED{"Property still fails?"}
    ACCEPTED -->|"Yes"| UPDATE["Accept: update the counterexample and the graph"]
    ACCEPTED -->|"No"| CACHE["Reject: cache so we don't retry"]

    UPDATE --> MORE
    CACHE --> MORE

    MORE{"More operations to try?"}
    MORE -->|"Yes"| PICK
    MORE -->|"No"| CONFIRM

    CONFIRM{"All values converged but nothing improved?"}
    CONFIRM -->|"Yes"| CONFIRM_CHECK["Convergence confirmation: probe each converged value one step below its floor"]
    CONFIRM -->|"No"| RELAX

    CONFIRM_CHECK --> RELAX

    RELAX{"Replacement rejected by shortlex but nothing else improved?"}
    RELAX -->|"Yes"| RELAX_ROUND["Relax round: perturb values to unlock shortlex-blocked structural operations"]
    RELAX -->|"No"| BUDGET

    RELAX_ROUND --> BUDGET

    BUDGET{"Improved this cycle?"}
    BUDGET -->|"Yes"| PICK
    BUDGET -->|"No, but stall budget remains"| PICK
    BUDGET -->|"No, stall budget exhausted"| ORDER

    ORDER["Reorder elements into natural numeric order"] --> RETURN
    RETURN["Return minimal counterexample"]
```

## What the reducer tries

The graph identifies which operations are available and estimates how much each one would reduce the counterexample. Ten encoders compete in the priority queue each cycle:

| Encoder | What it does |
|---|---|
| **Deletion** | Remove elements from sequences. Tries batch removal first (halving, quartering, cross-sequence), then per-element, then aligned removal across siblings. |
| **Migration** | Move elements from earlier sequences into later ones to enable further deletion. |
| **Substitution** | Replace a subtree with a smaller one from the same recursive generator, or promote a descendant pick to replace its ancestor. |
| **Branch pivot** | Try selecting a different branch at a pick site, using a minimized version of the alternative. |
| **Value search** | Drive each integer value toward its simplest form through interpolation, binary search, and linear scan phases. |
| **Float search** | Drive each floating-point value toward zero using IEEE 754 bit pattern ordering, with the same interpolation → binary → linear progression. |
| **Lockstep** | Search pairs of coupled values in coordinated steps when independent search on either stalls. |
| **Redistribution** | Shift value between type-compatible parameters to find a simpler combination. |
| **Sibling swap** | Swap adjacent sibling elements to improve shortlex ordering. Results may be overridden by the numeric reorder pass. |
| **Bound value search** | Joint search over a controlling value and its dependent subtree or values. Each upstream candidate triggers a full downstream exploration. Deferred to stall cycles. |

At the end of each cycle, two recovery passes may run before the stall budget is checked:

| Pass | When it runs | What it does |
|---|---|---|
| **Convergence confirmation** | Nothing improved and all values converged. | Probes each converged value below its floor to detect stale bounds. If any succeed, the floor was set too early. |
| **Relax round** | Nothing improved and a replacement was shortlex-rejected. | Perturbs leaf values upward to unlock structural operations that a value-minimized sequence blocked. Commits the perturbation only if the resulting structural reduction outweighs the value cost. |

After the cycle loop exits, one final pass runs:

| Pass | What it does |
|---|---|
| **Numeric reorder** | Sorts sibling elements into ascending numeric order. The reducer works in shortlex order internally, which is consistent but not intuitive to read — this converts to the ordering a user would expect. |

## Design principles

- **No fixed phases.** Structural and value operations compete in a shared priority queue, so the reducer naturally prioritizes big structural cuts early and fine value tuning late.
- **Rebuild on structural acceptance.** The graph is rebuilt from the tree after every structural acceptance. Value-only leaf changes are applied in place without rebuilding.
- **Incremental source rebuild.** When rebuilding candidate sources after a structural acceptance, self-similarity groups unaffected by the change are skipped, avoiding redundant substitution pair enumeration.
- **Rejection caching.** Structural replacements (branch pivots, substitutions) are value-independent, so a rejection is cached by identity alone and persists across value changes. Deletions depend on values and use a finer-grained cache.
- **Convergence tracking.** Once a value search converges, the floor is recorded and reused as a warm start if values shift later. Leaves at their floor are skipped.
- **Stall-cycle gating for expensive operations.** Bound value search (joint search across dependent parameters) only fires when cheaper operations have stalled.
- **Step-by-step execution.** The reducer is implemented as an explicit state machine (`ReductionMachine`) where each call to `next()` performs one unit of work — selecting a source, producing a candidate, checking the property, or rebuilding the graph — and returns a transition describing what happened. This makes the reducer's internal control flow inspectable and enables per-step wall-time measurement (dispatch, encode, decode, rebuild, convergence confirmation, relax, reorder).
