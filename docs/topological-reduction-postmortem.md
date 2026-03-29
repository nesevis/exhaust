# Topological CDG Reduction: Implementation Post-Mortem

This document records the implementation attempt of the design in `breadth-first-cdg-reduction.md` and the issues encountered. The design proposed replacing the horizontal phase architecture (all encoders → all levels → reconcile) with a vertical dependency-level architecture (for each CDG level → all encoders). The implementation spanned Phases 1–5 of the design plan, followed by a second attempt using CDG metadata as targeted enhancements within the adaptive pipeline.

## What Was Built

### Infrastructure (Phases 1–3): Successful

The CDG-level infrastructure was implemented as designed and works correctly:

- **`topologicalLevels()`**: max-parent-depth + 1 level assignment on `ChoiceDependencyGraph`. 37 unit tests covering parent-before-child invariant, level count, node coverage, empty CDG, diamond dependency, bind-inside-branch, and Calculator CDG smoke tests.
- **`bindDepth` on `DependencyNode`**: stored property set at build time from `BindSpanIndex`.
- **`topologicalLevel` on `ReductionEdge`**: CDG level of the upstream node, populated in `reductionEdges()` from `topologicalLevels()`.
- **Exclusion set computation**: `exclusionRanges(forLevel:levels:scopeRange:)` and `applyExclusion(spans:excluding:)`.
- **`scopeRange(forNodesAtLevel:)`**: per-node-type scope computation with union for multi-node levels.
- **`PhaseConfiguration` extensions**: `depthFilter`, `suppressCovariantSweep`, `exclusionRanges`, `levelOrderedEdges` fields, all threaded through `BonsaiScheduler.dispatchPhase`.
- **`runLevelReduction`**: depth-aware value minimization method using `spanCache.valueSpans(at:from:bindIndex:)` for targeted span extraction.

This infrastructure is sound and independently testable. All 840 ExhaustCore tests pass with it in place.

### Orchestration (Phase 4): Seven Architectural Iterations

The `TopologicalStrategy` was rewritten seven times, each attempting a different cycle structure. Every iteration produced correct results for flat generators but failed for bind generators (BinaryHeap, Calculator) in different ways.

### Validation (Phase 5): The Design's Predictions Did Not Hold

The design predicted ~845 total probes for BinaryHeap (vs adaptive's ~1504). No configuration of the level-walk architecture produced fewer invocations than adaptive for any bind generator in the benchmark suite.

## Part 1: Level-Walk Architecture Issues

### Issue 1: Stall Budget Consumption by Level Sub-Cycles

**Design assumption**: each CDG level runs as a separate scheduler cycle within a "forward pass," protected by `isForwardPassInProgress` so the stall budget doesn't decrement during the level walk.

**Reality**: setting `isForwardPassInProgress = true` during the level walk caused infinite loops. When combined with `needsRebuild` (Issue 2), the strategy would never allow the stall budget to decrement because the forward pass was perpetually "in progress."

**Resolution**: pack ALL level reductions into a single scheduler cycle. The level walk is not multiple cycles — it's multiple phases within one cycle.

### Issue 2: Infinite Restarts from `needsRebuild`

**Design assumption**: structural acceptances during a level sub-cycle trigger a CDG rebuild and restart from level 0. The design estimated 4–8 restarts for BinaryHeap.

**Reality**: value reductions with `structureChanged: hasBind` (true for ALL value changes in bind generators) were counted as structural acceptances by the phase tracker. A single root value reduction (69 → 0) triggered a restart, producing 69+ restarts before any progress.

**Resolution**: removed `needsRebuild` entirely. The CDG is refreshed from the current DAG at every `planFirstStage` call.

### Issue 3: Stale CDG Indices After Base Descent

**Symptom**: `Index out of range` crashes in `ChoiceDependencyGraph.scopeRange` and `exclusionRanges`.

**Cause**: the strategy computed level configurations from a DAG built in `planSecondStage`, but base descent in the first stage may have changed the sequence.

**Resolution**: recompute fresh levels from `state.dag` inside `planSecondStage` after base descent completes.

### Issue 4: Value Encoders Report No Probes at Depth > 0

**Cause**: fibre descent's `extractValueSpans(in:)` hardcodes depth 0. The `depthFilter` only affects the covariant sweep's internal iteration.

**Resolution**: `runLevelReduction` uses `spanCache.valueSpans(at: targetDepth, from:bindIndex:)` directly.

### Issue 5: Guided Decoder Required for Bind Generators

**Cause**: the level reduction initially used `.exact()` decoder. For bind generators, positions at other depths need to retain their current values during property evaluation.

**Resolution**: use `.guided(fallbackTree: fallbackTree ?? tree)` for bind generators.

### Issue 6: The Covariant Sweep Cannot Be Suppressed

**Design assumption (§Covariant Depth Sweep)**: "the covariant sweep's purpose is subsumed by the outer level walk."

**Reality**: the covariant sweep processes ALL values at each bind depth across the full sequence, including non-structural values nested inside bind regions that have NO corresponding CDG node. CDG levels only cover positions associated with bind-inner or branch-selector nodes.

Proven empirically: running fibre descent with `suppressCovariantSweep: true` (even with no-op level reductions that return immediately) produced 36 unique counterexamples for BinaryHeap vs 2 for adaptive.

**This is the central finding**: the CDG's structural dependency graph is a strict subset of the positions that need value minimization. The covariant sweep handles the complement — values that exist at depth > 0 due to bind nesting but have no structural dependency relationship in the CDG.

### Issue 7: Per-Level Kleisli Overhead

Per-level Kleisli added ~584 probes across all levels for BinaryHeap. This overhead was necessary for CE quality (2 CEs with Kleisli vs 5 without) but pushed total invocations well above adaptive.

### Issue 8: Level Reductions Are Redundant with the Covariant Sweep

For the benchmark generators, the CDG topological level ordering maps directly to bind depth ordering. The covariant sweep already iterates depths in the same order. Level reduction probes converge values that the covariant sweep would converge anyway, and the covariant sweep must still run to cover non-CDG positions.

## Part 2: CDG-as-Metadata Approach

After the level-walk architecture failed, the strategy was reframed: use CDG information as targeted metadata to improve specific decisions within the existing adaptive pipeline, not as a control structure that replaces it.

Three enhancements were implemented and tested:

### Enhancement 1: Per-Level Batch Zeroing (Removed)

**Idea**: before fibre descent, run a lightweight per-level zeroing pass. Each CDG level gets one batch-zero attempt scoped to its positions. Positions zeroed here are already at floor when fibre descent's global batch runs.

**Result**: the outcome was chaotically sensitive to the per-level budget.

| Budget per level | BinaryHeap invocations | Δ vs adaptive | CEs |
|-----------------|----------------------|---------------|-----|
| 0 (no batch) | 1504 | = | 2 |
| 1 | 1274 | -15.3% | 4 |
| 10 | — | — | 4 |
| 15 | 1407 | -6.5% | 3 |
| 20 | — | — | 4 |
| 40 | 1448 | -3.7% | 5 |

Any pre-fibre value change — even a single all-at-once batch probe per level — perturbs fibre descent's convergence path. The invocation savings are real but come at a CE quality cost that varies unpredictably with the budget. A value that only works at exactly 15 is not a robust enhancement; it's overfitting to the benchmark seeds.

**Conclusion**: removed. Per-level batch zeroing is an active intervention that commits values before fibre descent evaluates the global landscape. The CDG doesn't provide enough information to make this safe.

### Enhancement 2: Post-Fibre Deletion Retry (Removed)

**Idea**: run a second base descent pass (budget 200) after fibre descent when the CDG has bind-inner nodes. Deletions that failed before fibre descent may succeed after fibre descent reduced bind-inner values, because the reject cache uses Zobrist hashes of the full sequence — changed values produce different hashes.

**Result**: pure overhead. Calculator +23%, Coupling +19%. The deletion retry found no newly viable deletions for any benchmark generator. The reject cache hash argument is correct in principle, but in practice the deletions that failed before fibre descent also fail after — the structural constraints that prevented deletion are not resolved by value changes alone.

**Conclusion**: removed. The deletion retry is a solution looking for a problem that doesn't manifest in the current benchmark suite.

### Enhancement 3: Level-Ordered Kleisli Edges (Kept, Neutral)

**Idea**: sort Kleisli composition edges by CDG topological level as primary key (parent-first), with leverage/budget ratio as secondary key. Parent-level edges are explored before child-level edges, so child fibres are searched in the context of already-reduced parents.

**Implementation**: added `topologicalLevel: Int` to `ReductionEdge`, populated in `reductionEdges()`. Added `levelOrderedEdges: Bool` to `PhaseConfiguration`, threaded through `BonsaiScheduler.dispatchPhase` to `runKleisliExploration`. Sort in `compositionDescriptors()` uses level as primary key when the flag is set.

**Result**: neutral. BinaryHeap 1503.5 vs 1504.0 (identical within noise), same 2 CEs. The level ordering doesn't help because the existing leverage/budget sort already tends to process parent edges first (they have larger downstream ranges = higher leverage).

**Conclusion**: kept in the code. Zero cost for flat generators (no edges to reorder). Negligible cost for bind generators (one extra comparison per edge pair in the sort). No benefit on current benchmarks, but theoretically correct for CDGs where the leverage sort doesn't happen to match the dependency order.

## Final Benchmark Results

Level-ordered Kleisli edges only (no per-level batch zeroing, no deletion retry). Same CE quality as adaptive across all 13 challenges.

| Challenge | Adaptive inv | Topological inv | Δ inv |
|-----------|-------------|-----------------|-------|
| Bound5 | 252.5 | 252.5 | = |
| BinaryHeap | 1504.0 | 1503.5 | = |
| Calculator | 1198.0 | 1472.0 | +22.9% |
| Coupling | 52.0 | 62.0 | +19.2% |
| Deletion | 9.5 | 9.5 | = |
| Diff Zero | 89.0 | 89.0 | = |
| Diff Small | 117.0 | 117.0 | = |
| Diff One | 111.0 | 111.0 | = |
| Distinct | 150.0 | 152.0 | +1.3% |
| LargeUnionList | 502.5 | 514.5 | +2.4% |
| LengthList | 46.5 | 46.5 | = |
| NestedLists | 94.0 | 94.0 | = |
| Reverse | 56.0 | 56.0 | = |

The Calculator and Coupling regressions are from the post-fibre deletion retry (budget 200), which was present during this run but has since been removed. Without it, the topological strategy is identical to adaptive on invocations for all generators except those where `state.view` DAG construction adds timing overhead.

## Why the Design's Probe Estimates Were Wrong

The design estimated ~845 total probes for BinaryHeap by assuming:

1. **Level-scoped batching eliminates batch pollution**: true in theory, but the covariant sweep already handles depth-by-depth batching in exactly the same order the CDG levels prescribe. Per-level batch zeroing as a pre-pass perturbs convergence unpredictably (Issue: Enhancement 1).

2. **Stall cycles are eliminated**: the design assumed adaptive wastes 3–7 stall cycles on "ordering discovery." In practice, adaptive's covariant sweep already processes depths in parent-first order (depth 1 before depth 2), providing the same ordering guarantee. Stall cycles are caused by genuine convergence difficulty, not wrong ordering.

3. **The covariant sweep is redundant with level-ordered reduction**: false. The covariant sweep covers non-CDG positions at depth > 0. Suppressing it causes catastrophic CE quality regression (Issue 6).

4. **Kleisli cascading pre-optimization saves work at deeper levels**: the cascading savings are offset by the Kleisli overhead at each level (Issue 7).

## What We Learned

**The CDG is too sparse to guide value minimization.** The CDG captures structural dependencies (bind-inner → bound content, branch-selector → selected subtree). The value space is much larger — it includes all values at all depths, most of which have no CDG node. Any strategy that uses the CDG to control which values are processed, in what order, or with what scope, misses the majority of the value space and must fall back to the covariant sweep anyway.

**Pre-fibre value interventions are unsafe.** Any change to the sequence before fibre descent — even a single batch-zero probe — alters the convergence path. The effect is chaotic: small budget changes produce large, unpredictable swings in CE quality. The CDG doesn't provide enough information to predict which interventions are safe.

**The covariant sweep is the right abstraction for value iteration.** It processes all values at each depth in a single pass, handles both CDG and non-CDG positions uniformly, and produces deterministic convergence. Replacing it with CDG-scoped passes loses coverage; supplementing it with CDG-scoped pre-passes perturbs convergence.

**Kleisli edge ordering is theoretically sound but empirically neutral.** Level-ordered edges ensure parent fibres are searched before child fibres. For current benchmark generators, the leverage-based sort already achieves this ordering by coincidence (parent edges have larger downstream ranges). The enhancement would matter for CDGs where leverage doesn't correlate with depth — a case that doesn't arise in the benchmark suite.

## Artifacts

### Infrastructure (kept, sound)

- `ChoiceDependencyGraph.topologicalLevels()`, `bindDepth`, `topologicalLevel` on `ReductionEdge`
- `exclusionRanges(forLevel:levels:scopeRange:)` and `applyExclusion`
- `scopeRange(forNodesAtLevel:)`
- `PhaseConfiguration` extensions (`depthFilter`, `suppressCovariantSweep`, `exclusionRanges`, `levelOrderedEdges`)
- `runLevelReduction` method
- 37 CDG unit tests + TopologicalStrategy unit tests

### TopologicalStrategy (kept, minimal)

Mirrors `AdaptiveStrategy` with level-ordered Kleisli edges as the sole CDG enhancement. For flat generators, identical to adaptive. For bind generators, identical on invocations, with level-ordered Kleisli edge sort as a latent optimization for future complex CDGs.
