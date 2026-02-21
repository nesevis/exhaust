# Reducer Phase A Implementation Tickets

This document turns Phase A from `docs/reducer-pass-analysis-and-improvement-plan.md` into implementation-ready tickets.

## Ticket A1: Add Per-Pass Probe Budgets

## Objective
Bound worst-case oracle-call growth inside expensive reducer passes.

## Scope
- `deleteAlignedSiblingWindows`
- `redistributeNumericPairs`
- `reduceValuesInTandem`

## Implementation
1. Add a lightweight `ProbeBudget` utility (remaining count + consume/check API).
2. Add per-pass budget values to shrink configuration (fast/slow defaults).
3. Consume budget on every candidate that reaches materialization attempt.
4. Exit pass early when budget exhausted.
5. Emit budget-exhausted reason in instrumented logging.

## Acceptance Criteria
1. Each pass has an explicit configurable budget in `.fast` and `.slow`.
2. A pass never performs more materialization attempts than its budget.
3. Existing shrink outputs for current pathological fixtures are unchanged.
4. Pathological runs terminate with bounded pass-local probe counts.
5. Instrumented logs clearly indicate budget exhaustion when it occurs.

## Verification
- Add tests that force each pass into high-probe scenarios and assert probe cap respected.
- Run existing shrinking challenge suites and verify output equivalence.

---

## Ticket A2: Incremental Non-Semantic Metadata Cache

## Objective
Eliminate repeated full-sequence scans for `nonSemanticValueCount(in:)` in hot inner loops.

## Scope
- Primarily `redistributeNumericPairs`
- Reusable by other passes

## Implementation
1. Introduce a `SequenceSemanticStats` helper:
- tracks `nonSemanticCount`
- can be initialized from sequence once
- supports `applying(changes:)` style delta updates for mutated indices
2. Replace probe-time `nonSemanticValueCount(in: probe)` scans with delta update from current stats.
3. Keep canonical fallback path behind a debug assert for parity during rollout.

## Acceptance Criteria
1. No hot loop calls full-sequence `nonSemanticValueCount(in:)` for probe candidates.
2. Updated count from delta path always matches full recompute in debug validation mode.
3. No behavior change in shrink outputs on current challenge suites.
4. Wall-clock and/or oracle-per-second improves on pathological inputs.

## Verification
- Unit tests for delta updates across value/reduced transitions.
- A/B instrumentation comparing full-scan vs delta count on sampled candidates.

---

## Ticket A3: Remove Dead `containerID` Work in Redistribute Pass

## Objective
Reduce noise and overhead from unused container tracking.

## Scope
- `ReducerStrategies+RedistributeNumericPairs.swift`

## Implementation
1. Remove `containerID` from candidate tuple and collection logic.
2. Delete boundary-crossing increments that only existed for this tuple field.
3. If future gating is desired, reintroduce via dedicated optional policy hook (not inline leftovers).

## Acceptance Criteria
1. No `containerID` field or maintenance logic remains in pass.
2. Pass behavior (accepted candidates and final output) unchanged relative to pre-change baseline.
3. Code compiles with fewer local variables and no dead comments about cross-container-only behavior.

## Verification
- Snapshot run on representative seeds before/after to compare final shrinks.
- Static grep check confirms no stale `containerID` references.

---

## Ticket A4: Reuse RangeSet Assembly in Aligned Deletion Pass

## Objective
Cut repeated `RangeSet` rebuild costs for contiguous window probing.

## Scope
- `deleteAlignedSiblingWindows`

## Implementation
1. Precompute per-slot range contributions once for a cohort.
2. Build prefix (or rolling) `RangeSet` unions so contiguous windows can be materialized with incremental operations.
3. Reuse builder storage across monotonic and non-monotonic probe paths.
4. Keep candidate generation deterministic and equivalent.

## Acceptance Criteria
1. Contiguous probe paths no longer rebuild full `RangeSet` from scratch each time.
2. Generated candidate ranges are identical to old implementation for same `(slotStart, size)`.
3. No output changes in existing challenge tests.
4. Measurable reduction in CPU time for aligned-deletion-heavy traces.

## Verification
- Golden test for produced deletion index sets across sample cohorts.
- Benchmark microtest around cohort window generation.

---

## Ticket A5: Precompute Tandem Window Metadata

## Objective
Reduce allocations/hashing and repeated setup inside `reduceValuesInTandem`.

## Scope
- `ReducerStrategies+ReduceValuesInTandem.swift`

## Implementation
1. Introduce a `TandemWindowPlan` struct containing:
- window indices
- tag
- original entries
- original semantic distances (when needed)
- disallow-away flag
2. Build plans once per group/index set, then probe against plans.
3. Avoid repeated `Array(indexSet[offset...])` and per-window dictionary reconstruction.
4. Share mutation/evaluation code between probe closure and fallback reconstruction.

## Acceptance Criteria
1. Window setup allocations reduced (confirmed by profiler or allocation counters).
2. No repeated semantic-distance dictionary creation inside probe closure path.
3. Pass behavior unchanged on existing challenge tests.
4. Source complexity reduced (lower function length / lower branching in main pass function).

## Verification
- Unit tests for plan generation from bare-value and container-aligned groups.
- Trace comparison on `Bound5` pathological cases to ensure equivalent accepted steps.

---

## Delivery Order and Definition of Done

## Recommended Order
1. A3 (small cleanup)
2. A1 (safety bound)
3. A2 (biggest inner-loop gain)
4. A4
5. A5

## Definition of Done (for Phase A overall)
1. All five tickets merged.
2. Challenge suites pass with stable expected shrink outputs.
3. Pathological traces show bounded probe behavior.
4. Codebase has reduced duplicate probe scaffolding and improved local readability in touched passes.
