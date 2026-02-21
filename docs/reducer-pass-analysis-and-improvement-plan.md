# Reducer Pass Analysis and Improvement Plan

## Scope
This document analyzes the three reducer passes that were iterated during the Bound5 / LargeUnionList / Difference regressions:

1. `deleteAlignedSiblingWindows`
2. `redistributeNumericPairs`
3. `reduceValuesInTandem`

Files:
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+DeleteAlignedSiblingWindows.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+RedistributeNumericPairs.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+ReduceValuesInTandem.swift`

---

## 1) Control-Flow Analysis by Pass

## `deleteAlignedSiblingWindows`

### Current flow
1. Build deletion cohorts from three sources:
- container-pair structural alignment (`alignedContainerCohorts`)
- sibling groups (`alignedSiblingGroupCohorts`)
- root sequence containers (`rootSequenceContainerCohorts`)
2. For each cohort:
- iterate sliding start `slotStart`
- use `AdaptiveProbe.findInteger` over contiguous window size
- if probe fails monotonic assumptions (`k == 0`), run non-monotonic fallback probes over selected sizes
- after contiguous attempts, run bounded subset search (`bestSubsetDeletionCandidate`) over non-contiguous slot subsets
3. Return first accepted candidate.

### Pattern characteristics
- Multiple candidate-generation paths with very similar logic.
- Three-level fallback stack:
  - monotonic contiguous search
  - non-monotonic contiguous probes
  - non-contiguous subset combinatorics
- Heavy use of candidate cloning + `RangeSet` rebuilding.

### Complexity growth
Previous effective shape (before recent edits):
- roughly `O(cohorts * slots * log(slots) * M)`

Current worst-case shape:
- contiguous search: `O(C * S * log S * M)`
- non-monotonic probes: `O(C * S * P * M)` (`P` = probe sizes, small but non-zero)
- subset fallback: `O(C * 2^S * M)` for `S <= 10`

`M` is cost of replay/materialize/property.

The exponential subset stage is bounded but still a major cost amplifier on difficult cohorts.

### Key pressure points
- Recomputing `RangeSet` from scratch for each size/mask.
- Duplicate materialization logic across monotonic, non-monotonic, subset branches.
- Returning first success can lock in locally-good but globally-poorer deletions, increasing outer-loop count.

---

## `redistributeNumericPairs`

### Current flow
1. Collect numeric candidates by `TypeTag`.
2. For each pair `(ci, cj)` and both orientations `(ci,cj)` and `(cj,ci)`:
- read fresh current values
- compute target distance / semantic-distance gates
- run `AdaptiveProbe.findInteger(k)`
- for each probe candidate:
  - apply pair move
  - accept only if shortlex or non-semantic-count improves
  - materialize + property check
  - keep probe if pair multiset changes
3. If monotonic search produces no commit candidate, run non-monotonic fallback on selected `k` values (distance edges + fractions + wrapping deltas).
4. Commit best fallback by semantic-count then shortlex.

### Pattern characteristics
- Pairwise search with bilateral orientation doubles search surface.
- Heuristic gating moved from pure shortlex to hybrid shortlex/semantic-distance.
- Non-monotonic fallback added to break local monotonicity failures.

### Complexity growth
Previous effective shape:
- approximately `O(V^2 * log D * M)` with stronger pre-gates and no fallback branch.

Current effective shape:
- pair/orientation loop: `O(2 * V^2)`
- monotonic probe phase: `O(log D)` oracle checks per orientation
- fallback phase: `O(F)` additional checks per orientation (`F` small but non-trivial)
- each probe now may also compute `nonSemanticValueCount(in:)` => extra `O(S)` scan

Overall: `O(V^2 * (log D + F) * (M + S))`

This pass can become expensive even when no final commit occurs.

### Key pressure points
- `currentNonSemanticCount` is cached, but `nonSemanticValueCount(in: probe)` is recomputed from full sequence per probe.
- `containerID` is still computed but no longer used for gating (dead overhead).
- Fallback candidate construction duplicates monotonic code path.
- Pair-multiset protection is correct for cycles but adds extra compare churn.

---

## `reduceValuesInTandem`

### Current flow
1. For each sibling group, derive `tandemIndexSets`:
- direct value sibling ranges
- aligned internal value offsets across container siblings
2. For each index set, test suffix windows (`offset` shifting).
3. For each window:
- enforce homogeneous supported numeric tags
- compute target direction/distance from first value
- binary search `delta`
- for each probe:
  - mutate all window values
  - enforce shortlex-first-difference monotonicity
  - enforce away-move guard for high-arity bare-value windows
  - materialize + property check
- fallback reconstruct from `bestDelta` if bookkeeping did not retain probe
4. Commit last best accepted probe for window.

### Pattern characteristics
- Structural broadening from a single sibling-range window to multiple aligned windows and suffixes.
- Added semantic monotonicity guard to avoid translation cycles.
- More per-window setup and per-probe checks than original implementation.

### Complexity growth
Previous effective shape:
- approximately `O(G * log D * M)`

Current effective shape:
- window expansion: `W` windows per group (aligned sets + suffix offsets)
- per-probe mutation cost across `R` window entries
- semantic-distance/away checks per entry

Overall: `O(G * W * log D * (M + R))`

`W` can be materially larger on container-rich structures.

### Key pressure points
- Allocating `Array(indexSet[offset...])` per offset.
- Rebuilding semantic-distance dictionary per window.
- Reapplying similar candidate mutation logic in probe and fallback reconstruction.

---

## 2) Cross-Pass Patterns Increasing Cost and Risk

1. **Repeated candidate evaluation scaffolding**
- shortlex guard
- reject-cache lookup
- materialize
- property check
- reject-cache insert on failure

Implemented repeatedly with slight variation, which increases maintenance drift and bug risk.

2. **Ad hoc fallback ladders**
- Each pass now has custom monotonic + non-monotonic behavior.
- No shared policy for when to escalate to expensive fallback.

3. **Expensive probes without pass-level budgets**
- No hard cap for per-pass oracle attempts inside a loop.
- Pathological cases can continue exploring low-yield candidates.

4. **Commented complexity annotations now understate practical worst-case**
- Especially for subset fallback and semantic-count scans in inner loops.

5. **High branch-factor, low cohesion methods**
- A lot of logic in single methods, reducing readability and making correctness changes risky.

---

## 3) Improvement Task List

## Phase A: Immediate Performance Stabilization (low risk)

1. **Add pass-local probe budgets**
- Add max probe counters per pass invocation (configurable).
- Stop non-monotonic or subset fallback once budget is exhausted.
- Benefit: bounds worst-case oracle blowups.

2. **Memoize per-sequence value metadata**
- Cache semantic simplest / shortlex / non-semantic flags by index.
- Update incrementally for changed indices instead of full sequence scans.
- Benefit: removes repeated `O(S)` scans in probe loops.

3. **Remove dead `containerID` work in `redistributeNumericPairs`**
- Stop computing container IDs unless gate is reintroduced.
- Benefit: cleaner code and less per-entry overhead.

4. **Reuse `RangeSet` assembly buffers in delete pass**
- Build incremental prefix unions for contiguous windows.
- Avoid reconstructing from scratch for nearby sizes.
- Benefit: lower constant factors in hottest loop.

5. **Precompute and reuse window metadata in tandem pass**
- Store semantic distances and index arrays once per index set.
- Avoid repeated dictionary rebuild per offset.
- Benefit: lower allocation and hashing overhead.

## Phase B: Algorithmic Improvements (medium risk)

6. **Replace subset exhaustive search with beam search in delete pass**
- Keep top-K partial subsets by structural score (size + shortlex gain estimate).
- Maintain bounded frontier instead of `2^S` masks.
- Benefit: near-best deletions with bounded cost.

7. **Unify monotonic + fallback probing under one adaptive strategy object**
- Shared API for generating candidate deltas/sizes (`nextProbe` policy).
- Consistent stopping criteria across passes.
- Benefit: easier tuning and lower duplication.

8. **Introduce gain heuristic before materialization**
- Compute cheap score (deleted spans, target-distance drop, non-semantic drop).
- Skip low-gain probes when a significantly better candidate already exists.
- Benefit: fewer expensive oracle calls.

9. **Add pair-priority ordering in `redistributeNumericPairs`**
- Sort candidate pairs by expected gain (`distance1`, semantic gap, tag risk).
- Try high-impact pairs first, optionally early stop after first strong win.
- Benefit: better improvements earlier, fewer total probes.

10. **Normalize acceptance semantics between passes**
- Decide one precedence model: shortlex-first vs semantic-count-first vs hybrid.
- Encapsulate in a shared comparator.
- Benefit: reduces oscillation and inconsistent local decisions.

## Phase C: Readability and Maintainability Refactor (medium/high effort)

11. **Extract shared `evaluateCandidate` helper**
- Signature should encapsulate:
  - structural guard(s)
  - reject-cache handling
  - materialize/property evaluation
  - optional scoring/recording
- Benefit: removes repeated error-prone blocks.

12. **Split each pass into explicit stages**
- `collectCandidates` / `propose` / `evaluate` / `commit`
- Keep each function short and single-purpose.
- Benefit: easier debugging and testability.

13. **Promote fallback policies to typed strategies**
- e.g. `MonotonicBinaryProbe`, `FixedFallbackProbe`, `BeamSubsetProbe`
- Benefit: clearer intent, simpler reasoning about complexity.

14. **Add invariant-focused unit tests per pass internals**
- No-away-move invariant for tandem.
- No-pure-swap commit invariant for redistribution.
- Structural validity + shortlex monotonicity for aligned deletion.
- Benefit: safer future tuning.

15. **Update complexity docs to two-tier form**
- “typical” and “bounded worst-case”.
- Include explicit fallback terms.
- Benefit: realistic expectations for pathological workloads.

## Phase D: Observability and Tuning Loop

16. **Add per-pass telemetry counters (non-instrumented mode optional)**
- probes attempted
- probes materialized
- cache hits
- commits
- fallback invocations
- Benefit: empirical tuning instead of guesswork.

17. **Add regression benchmark set for known pathologies**
- Bound5 pathological variants
- Difference test 3
- LargeUnionList pathological variants
- Benefit: preserve behavior while improving performance.

18. **Define acceptance SLOs for shrinker**
- e.g. max oracle calls per challenge class in `.fast` mode.
- Benefit: makes tradeoffs explicit and testable.

---

## 4) Suggested Execution Order

1. A1, A2, A3, A4, A5
2. D16 (telemetry) and D17 (benchmark harness)
3. B6, B9, B10
4. B7, B8
5. C11, C12, C13, C14, C15
6. D18 finalize SLOs

This order stabilizes runtime first, then improves heuristics, then refactors safely with instrumentation in place.

---

## 5) Expected Outcomes

If the above plan is executed:
- Oracle-call tails in pathological inputs should be bounded and more predictable.
- Fallback behavior becomes intentional rather than ad hoc.
- Cross-pass acceptance semantics become consistent, reducing cycles.
- Reducer strategy code becomes easier to reason about and safer to extend.
