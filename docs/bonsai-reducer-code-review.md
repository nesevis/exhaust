# Bonsai Reducer Code Review (March 2026)

Thorough review of the Bonsai reducer pipeline covering performance, correctness, and structural concerns. Findings are ordered by priority within each category.

## 1. Performance: Avoidable Work

### 1a. Redundant ChoiceDependencyGraph rebuilds in base descent

**File:** `ReductionState+Bonsai.swift:34`

`rebuildDAGIfNeeded()` unconditionally rebuilds on every call despite its name implying laziness. In the structural deletion inner loop it is called on every iteration, including when no acceptance occurred (the loop breaks immediately after a non-accepting pass). The DAG is then rebuilt again on the next outer-loop iteration.

**Fix:** Track a `dagDirty` flag (set on structural acceptance, cleared after build) to skip O(n) DAG reconstruction on repeated no-op loops.

### 1b. `computeEncoderOrdering` bypasses SpanCache

**File:** `ReductionState.swift:864-865`

`computeEncoderOrdering()` calls `ChoiceSequence.extractContainerSpans(from:)` and `ChoiceSequence.extractAllValueSpans(from:)` directly, not through the `SpanCache`. These are O(n) walks. The span cache is invalidated at cycle start, so the first real access populates it — but this method doesn't use the cache, so the work happens twice.

**Fix:** Route through `spanCache` methods instead.

### 1c. `allValueCoordinatesConverged()` is O(n) per `state.view` access

**File:** `ReductionState.swift:405-428`

Called via `state.view` at the top of every cycle for strategy planning, and again within fibre descent gating. The result is stable within a cycle (only changes on acceptance).

**Fix:** Cache the result per cycle and invalidate on acceptance.

### 1d. `BindSpanIndex` rebuilt redundantly from scratch

**File:** `BindSpanIndex.swift:30`

`BindSpanIndex(from:)` calls `ChoiceSequence.extractContainerSpans(from:)` internally. The span cache also calls this. When `accept(result, structureChanged: true)` fires (`ReductionState.swift:522`), it rebuilds the bind index AND invalidates the span cache, so the container span walk happens twice.

**Fix:** Have `BindSpanIndex.init` accept pre-extracted container spans as a parameter.

### 1e. `computeDependentDomains` performs unbudgeted materializations

**File:** `ReductionState+Bonsai.swift:1343-1440`

For each upstream ladder value times each dependent downstream region, a full `ReductionMaterializer.materialize` is called. With typical ladder sizes of 6-15 and 2-3 dependencies, this is 12-45 materializations per cycle just for domain discovery. Each materialization also constructs a `ChoiceSequence`, `BindSpanIndex`, and so on. These materializations do not count against `legBudget`.

**Fix:** Either budget these or consider caching domain maps across cycles when the upstream value has not changed.

### 1f. Redundant `flatMap` in antichain greedy extension

**File:** `ReductionState+Bonsai.swift:496`

In the greedy extension loop of `findMaximalDeletableSubset`, `best.flatMap(\.spans)` is recomputed on every iteration, allocating a new array each time.

**Fix:** Maintain a running `bestSpans` array and append incrementally when a candidate is accepted.

### 1g. MutationPool pair composition allocates per-pair

**File:** `MutationPool.swift:99-107`

Each of up to 190 pair compositions builds a fresh `RangeSet`, copies the full sequence, and calls `removeSubranges`.

**Fix:** Pre-compute `RangeSet`s for individuals and merge them for pairs rather than rebuilding from spans.

### 1h. `StructuralIsolator.project` — linear scan for connected ranges

**File:** `StructuralIsolator.swift:73-77`

The `inConnected` array is populated by iterating every index in every connected range. For deeply nested bind structures with large ranges this can be quadratic.

**Fix:** Use `RangeSet<Int>` instead.

---

## 2. Potential Bugs / Correctness Concerns

### 2a. Verification sweep re-entry loop omits CycleOutcome tracking (HIGH)

**File:** `BonsaiScheduler.swift:343-380`

The re-entry loop after verification sweep staleness duplicates the main reduction loop but:

- Does NOT build `phaseDispositions` or `CycleOutcome`.
- Does NOT update `lastOutcome`, so the strategy's `planFirstStage` and `planSecondStage` see stale `priorOutcome` from the pre-verification cycle.
- Does NOT call `state.phaseTracker.reset()` between cycles.

For `StaticStrategy` this is mostly harmless (it doesn't read fine-grained signals), but for `AdaptiveStrategy` this causes incorrect gating decisions — for example, Phase 1 skip based on a stale `priorBaseUnproductive` flag, or Phase 3 skip based on stale `allEdgesClean`.

### 2b. Edge signal classification uses `lastAccepted` instead of `anyAccepted` (HIGH)

**File:** `ReductionState+Bonsai.swift:1246-1250`

The edge signal is classified as `exhaustedWithFailure` if `lastAccepted` is true. But `lastAccepted` tracks only the most recent probe. If the composition accepted probe 3 of 5, then probes 4 and 5 were rejected, `lastAccepted` is false and the signal is `.exhaustedClean` even though a failure was found.

This causes the adaptive strategy to incorrectly skip exploration on edges that had productive probes, potentially missing deeper reductions.

**Fix:** Track a separate `edgeAcceptedAny` flag per edge and use that for signal classification.

### 2c. Relax-round budget under-counting on rollback (HIGH)

**File:** `ReductionState.swift:997-1000`

When the relax-round rolls back after exploitation (base+fibre descent didn't produce a net improvement), `remaining` is decremented only by `explorationBudget.used`, NOT by the budget consumed by base descent and fibre descent during exploitation. The exploitation budget was `remaining - explorationBudget.used` and was mutated in-place, but on rollback `remaining` reverts to `remaining - explorationBudget.used`.

This means after a failed relax round, the caller thinks more budget is available than was actually consumed. Over multiple failed relax rounds the reducer can exceed its intended budget significantly.

**Fix:** Capture `exploitRemaining` before exploitation and compute the total consumed as `remaining - exploitRemaining` on rollback.

### 2d. Snapshot does NOT capture `rejectCache` or `edgeObservations` (MEDIUM)

**File:** `ReductionState.swift:435-447`

`Snapshot` captures sequence, tree, output, fallbackTree, bindIndex, bestSequence/Output, branchTreeDirty, spanCache, dominance, and convergenceCache. It does NOT capture:

- `rejectCache` — rollback leaves stale reject entries from probes tested against the now-rolled-back sequence. Zobrist hashes of rolled-back probes are unlikely to collide with restored-state probes, but it is a latent correctness risk.
- `edgeObservations` — rollback leaves observations recorded during the rolled-back phase.
- Encoder state (for example `productSpaceBatchEncoder.bindIndex`).

### 2e. `detectStaleness` accepts and returns on first stale coordinate

**File:** `BonsaiScheduler.swift:526-561`

`detectStaleness` returns on the first stale detection. If there are multiple stale coordinates, only the first is fixed. The post-verification fibre descent pass may or may not catch the others depending on budget. Not a bug, but the verification sweep can be incomplete.

### 2f. Convergence cache sibling invalidation is O(regions times changed)

**File:** `ReductionState.swift:538-549`

`invalidateConvergenceCacheSiblings` iterates all regions for every changed position. For generators with many bind regions and many value changes, this is O(regions times sequence_length).

**Fix:** Build a position-to-region lookup once per cycle.

---

## 3. Structural / Design Observations

### 3a. Duplicated main loop in verification re-entry

**File:** `BonsaiScheduler.swift:343-380` vs `BonsaiScheduler.swift:182-283`

The re-entry loop is a near-copy of the main loop without the full bookkeeping. Any change to the main loop must be mirrored in the re-entry loop.

**Fix:** Extract the loop body into a shared function.

### 3b. `bonsaiReduce` and `bonsaiReduceCollectingStats` are near-duplicates

**File:** `BonsaiReducer.swift:63-107` and `BonsaiReducer.swift:112-156`

These two methods are nearly identical, differing only in which `BonsaiScheduler` method they call and the return type. The visualization logic is duplicated.

### 3c. `totalMaterializations` tracking is fragile

Materialization counting is split between:

- The `defer` block in `runComposable` (`ReductionState.swift:583-586`).
- Manual accumulation in `runStructuralDeletion` (lines 272, 326, 342-344).
- Manual accumulation in `runKleisliExploration` (lines 1270-1272).
- Manual accumulation in `runRelaxRound` (lines 953-955).

The antichain and mutation pool bypass `runComposable` (they call `decoder.decode` directly), so manual accumulation is correct — but it is fragile and easy to break when adding new direct-decode paths.

### 3d. SpanCache invalidation is aggressive

`spanCache.invalidate()` is called at the start of every phase (base descent, fibre descent, deletion inner loop, joint bind-inner). Some of these invalidations are unnecessary — for example, if fibre descent made no structural changes, the span cache from base descent is still valid.

---

## 4. Minor Issues

### 4a. Relax-round exploration budget uses full `remaining` as hard cap

**File:** `ReductionState.swift:910`

The relax-round's exploration budget uses the entire `remaining` budget as its hard cap. For `StaticStrategy` the outer planner limits this to 325, but `AdaptiveStrategy` sets a 2000 ceiling, allowing the exploration phase alone to consume the full budget before exploitation starts.

### 4b. ZobristHash tag bits collapse date subtypes

**File:** `ZobristHash.swift:82-88`

`TypeTag.date` maps to 12 regardless of associated values (`intervalSeconds`, `timeZoneID`). All date types hash to the same tag bits, increasing Zobrist collisions for sequences mixing date generators with different intervals. Not a correctness bug (just more reject-cache misses), but reduces cache effectiveness.

### 4c. Magic sub-budget numbers

Budget constants (200 for branch simplification, 1200 for structural deletion, 600 for bind-inner) are inline in `runBranchSimplification`, `runStructuralDeletion`, and `runJointBindInnerReduction` rather than being named constants like the top-level phase budgets in `BonsaiScheduler`.

---

## Priority Summary

| Priority | Issue | Impact |
|----------|-------|--------|
| High | 2c: Relax-round budget under-counting on rollback | Budget overrun; wall-clock time exceeds intent |
| High | 2b: `lastAccepted` vs `anyAccepted` for edge signal | Incorrect edge observations, wrong adaptive gating |
| High | 2a: Re-entry loop missing CycleOutcome/lastOutcome | Stale strategy decisions in adaptive mode |
| Medium | 1a+1b: Redundant DAG rebuilds and span extractions | Unnecessary O(n) work per cycle |
| Medium | 1e: Unbudgeted domain discovery materializations | Hidden cost not reflected in budget |
| Medium | 2d: Snapshot doesn't capture rejectCache | Latent stale-cache risk on rollback |
| Medium | 3a: Duplicated main loop | Maintenance hazard |
| Low | 1c: `allValueCoordinatesConverged` recomputed per view | O(n) per cycle, cacheable |
| Low | 1f-1h: Intermediate allocations in antichain/mutation pool | Allocation pressure on hot paths |
| Low | 4a-4c: Budget caps, hash collisions, magic numbers | Minor quality-of-life |
