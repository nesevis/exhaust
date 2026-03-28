# Topological CDG Reduction

## The Idea

Replace the current horizontal phase architecture (all encoders → all levels → reconcile) with a vertical dependency-level architecture (for each CDG level → all encoders). The CDG's topological level traversal IS the reduction algorithm. Each dependency level is fully reduced before its dependents are touched.

The existing phase pipeline (structural → value → redistribution) is unchanged. It becomes an inner sub-cycle. The only addition is an outer loop that scopes WHERE the sub-cycle operates, based on CDG dependency levels.

For generators **without binds**, the CDG has no nodes. There are no levels. The entire sequence is leaf positions. The algorithm reduces to a single sub-cycle on the full sequence — functionally identical to `AdaptiveStrategy`.

For generators **with binds**, the outer loop adds dependency-ordered scoping. The phases themselves don't know they're scoped — they receive a narrower position range and operate normally. The intelligence is in the ordering and scoping, not in the encoders.

## Current Architecture and Its Problems

The current reducer runs in phases:
1. **Base descent**: structural deletion across the entire sequence
2. **Fibre descent**: value minimization across the entire sequence
3. **Kleisli exploration**: cross-level reconciliation for bind dependencies
4. **Relax round**: redistribution for coupled values
5. Repeat until stall

Each phase operates on ALL values at ALL dependency levels simultaneously. This creates systematic problems for bind-heavy generators.

### Stall Cycles

Fibre descent converges values independently at all levels, then Kleisli discovers they need coordinated cross-level changes. The reducer spends multiple cycles discovering coordination failures after the fact. A bind-inner value reduced in fibre descent invalidates its downstream, but the downstream isn't re-reduced until a later phase or a later cycle.

### Batch Pollution

`zeroValue` batch-zeros ALL values in the sequence at once as its first probe. If any value at ANY dependency level can't be zero, the entire batch fails — even if values at one specific level could all be zeroed together.

### Convergence Cache Staleness

Kleisli sets values externally (via guided lift with PRNG), but the convergence cache from a prior fibre descent pass still has floor entries from before Kleisli ran. The next fibre descent skips those positions because the cache says they're converged — even though Kleisli replaced them with different values.

### Wasted Probes

Structural deletion tries deleting content whose bind-inner hasn't been reduced yet. The deletion fails because the bind-inner still demands the old structure. After the bind-inner is reduced in a later cycle, the deletion would succeed — but the encoder already cached it as failed and won't retry.

## The New Algorithm

```
repeat:                                          // ← OUTER loop (stall-counted)
    build CDG from current choice sequence
    levels = CDG.topologicalLevels()

    for level in levels:                         // ← INNER loop (restartable)
        bindDepth = bindDepth of nodes at this level
        // For bind-inner levels: depthFilter = bindDepth (exclusive scope)
        // For branch-selector levels: depthFilter = nil, but EXCLUDE positions
        //   belonging to bind-inner CDG nodes at deeper levels (see §Branch-Selector
        //   Depth Exclusion)

        run sub-cycle(depthFilter, scopeRange):
            base descent    (structural deletion, branch simplification)
            fibre descent   (batch zeroing, binary search — filtered by depthFilter)
            exploration     (Kleisli on edges with upstream at this level)
            redistribution  (tandem reduction)

        if structural change accepted:
            rebuild CDG (positions shifted, downstream invalidated)
            restart INNER for-level loop from level 0
            (outer repeat loop is NOT restarted; stall counter resets)
            (convergence cache is fully cleared by structural acceptance;
             previously-converged levels re-converge cheaply — see §Probe Cost)

    // Final: full-sequence cleanup pass
    // Handles cross-level joint deletions, redistribution, and uncovered positions.
    run sub-cycle(depthFilter = nil, scopeRange = full sequence):
        base descent    (full CDG scopes, including cross-level antichain)
        fibre descent   (convergence cache skips already-converged positions)
        redistribution  (full-sequence sibling groups)

until stall budget exhausted (zero total acceptances across the entire forward pass
                              for maxStalls consecutive outer iterations)
```

### Outer Loop Termination

The outer loop uses the same `maxStalls` budget as the current cycle loop. One "stall" = one complete forward pass (all level sub-cycles + the cleanup pass) where the total acceptance count across every sub-cycle is zero. The cleanup pass counts: if the level walk finds nothing but the cleanup pass accepts a probe, the forward pass is productive and the stall counter resets. A forward pass where ANY sub-cycle at ANY level (including cleanup) accepts even one probe resets the stall counter — even if all other levels found nothing.

For `maxStalls=2` (`.fast`), the outer loop terminates after 2 consecutive fully-unproductive forward passes. A forward pass where level 2 makes progress (enabling level 0 to improve on the next pass) resets the counter — the algorithm gets another full pass to propagate the benefit upward.

Cross-level benefit propagation (level N's change enabling level M < N to improve) requires at least one additional forward pass. With `maxStalls=2`, the algorithm tolerates one unproductive pass after a productive one before terminating. For deep CDGs where cascading benefits take multiple passes, `.slow` (`maxStalls=8`) provides more room.

A structural acceptance within the inner level walk triggers a restart of the inner loop (from level 0), NOT a restart of the outer loop. The outer loop's stall counter counts complete forward passes, not inner restarts. A forward pass with structural acceptances followed by restarts counts as one productive pass (stall counter resets).

## CDG Structure: Bind-Inners vs Branch-Selectors

The CDG contains two kinds of nodes:

- **Bind-inner nodes**: from `._bound` / `.bind`. The inner value controls the generator structure of the bound content. Changing the inner value changes the downstream generator, producing different choice tree structure.
- **Branch-selector nodes**: from `.oneOf` / `Gen.pick`. The selected branch determines which subtree is active. The scope is the selected branch's content.

These have different scoping properties:

### Bind-Inner Scoping

For bind-inners, the scope is the bound content — generated by `forward(innerValue)`. Reducing the inner value produces a different bound generator. The scope range may change (shorter sequence for smaller depth). **Level-scoped reduction on bind-inner nodes means: reduce the inner value first, re-materialize the bound content, then reduce the values within the bound content.**

This is the case that level-ordering directly addresses: parent bind-inner values are reduced before their dependent bound content.

### Branch-Selector Scoping

For branch-selectors, the scope is the selected branch's subtree — everything inside the chosen alternative. Nested branch-selectors create a containment chain. **Level-scoped reduction on branch-selector nodes means: reduce the outermost branch's content first, then nested branches.**

This is a depth-first traversal of the expression tree, not a "reduce parents before children" strategy. For branch-selectors, the parent's value (which branch is selected) is determined by the pick entry — branch simplification (promotion/pivot) handles this in base descent, not value minimization. The ordering benefit is less clear than for bind-inners.

### Branch-Selector Depth Exclusion

A branch-selector at CDG level N uses `depthFilter = nil` — its content may span multiple bind depths. But its scope range can contain bind-inner CDG nodes at deeper levels (level N+1, N+2, and so on). If the branch-selector's sub-cycle runs fibre descent on the full scope without exclusion, it processes those deeper bind-inner values before their own level sub-cycle runs. This causes the same premature convergence the exclusive scope model was designed to prevent: the bind-inner value converges at an inappropriate time, and the deeper level's sub-cycle finds it already converged and skips it.

**Resolution**: branch-selector sub-cycles exclude positions owned by CDG nodes at deeper levels from all value-level phases. Concretely, for a branch-selector at level N with scope range S:

1. Collect all CDG nodes at levels > N whose ranges fall within S. For bind-inner nodes, the excluded range is `positionRange.lowerBound ... boundRange.upperBound` (the control value AND the bound content — see §Formal scopeRange Definition). For branch-selector nodes, the excluded range is just `positionRange` (the pick entry).
2. Exclude those ranges from fibre descent's span extraction AND from redistribution's sibling group construction. Both are value-level phases; both would cause premature convergence if they processed deeper-level positions.
3. Base descent still operates on the full scope (branch simplification and deletion are structural, not value-level).

This ensures branch-selector sub-cycles only process leaf values and branch-selector values within their scope — not bind-inner values that belong to deeper levels. The exclusion list is cheap to compute: it's a subset of the CDG's node list, filtered by level and position range.

For the fingerprint guard: bind-inner values inside a branch scope that are structure-controlling would trigger the guard if fibre descent tried to reduce them. The exclusion makes this redundant — those positions are never reached by the branch-selector's fibre descent. But the guard remains as a safety net for edge cases where the exclusion list is incomplete (for example, if a bind-inner appears inside a nested structure that the CDG doesn't fully classify).

**Nested branch-selectors**: the exclusion set includes ALL deeper CDG nodes, not just bind-inners. A branch-selector at level N+1 whose `positionRange` (the pick entry) falls within the current scope is excluded from fibre descent — correct, because pick values are structural (handled by branch simplification in base descent, not fibre descent). Base descent at level N CAN simplify the nested branch (promotion, pivot) because the exclusion only applies to fibre descent. If level N's branch simplification promotes the nested branch, the CDG rebuilds and the inner loop restarts — level N+1 no longer exists. If level N doesn't simplify it, level N+1 gets its own chance. At most one level simplifies any given branch. No conflict.

**Leaf value double-coverage**: for branch-selector levels, the exclusion covers the deeper branch-selector's `positionRange` (pick entry) but NOT the leaf values within the deeper branch's scope. In the Calculator example, positions 5 and 6 (add operands) are within BOTH level 1's scope (the outer `oneOf`'s content) and level 2's scope (the inner `oneOf`'s content). Level 1's fibre descent processes them; level 2's fibre descent also reaches them. This is intentional double-coverage, not a bug. The convergence cache deduplicates: if level 1's batch-zero succeeds (zeroing positions 5 and 6), the cache records the floor. Level 2's fibre descent finds them cached and skips in O(1). If level 1's batch fails (some values in the broader scope can't be zeroed), level 2 re-attempts with a narrower batch scoped to positions 4-6 — this is the level-scoped batching benefit.

Correctness is preserved because fibre descent is monotone (each probe can only improve or stall) and the convergence cache prevents committed regressions. Double-coverage costs at most O(1) per already-converged position — a cache lookup, not a property invocation.

**Partial convergence does not block narrower batches**: if level 1's fibre descent partially converges the scope (zeroing position 3 but leaving positions 5 and 6 at non-zero floors), the convergence cache records individual floors for positions 5 and 6. Level 2's batch-zero is NOT blocked by these floors — batch-zero constructs a candidate where ALL targeted values are set to zero and tests it as a single property invocation, bypassing the per-position convergence cache. The cache is consulted by individual binary search AFTER batch-zero, not during it. If level 2's batch-zero succeeds (zeroing positions 5 and 6 jointly), the cache entries are updated to floor=0. If it fails, individual binary search at level 2 consults the cache and finds the existing floors from level 1 — the narrower scope doesn't help for individual search, only for the joint batch probe.

### Calculator's CDG: A Mix

The Calculator generator with `Gen.recursive(depthRange:)` produces BOTH kinds of nodes:
- A bind-inner node from the `._bound` wrapping the depth draw (controls generator structure)
- Branch-selector nodes from each `oneOf(weighted: leaf, add, div)` at each depth level

The bind-inner (depth) is at CDG level 0. The branch-selectors are nested within the bound content. Whether level-scoped batching helps depends on which level the `add` operands fall at.

#### Walking Through `div(value(0), add(value(-6), value(6)))`

The choice sequence has:
1. Bind-inner: depth value (CDG level 0, bind-inner node)
2. Branch selector: outermost `oneOf` picked `div` (CDG level 1, branch-selector)
3. Value: `0` (leaf of `div`'s left child)
4. Branch selector: inner `oneOf` picked `add` (CDG level 2, branch-selector)
5. Value: `-6` (leaf of `add`'s left child)
6. Value: `6` (leaf of `add`'s right child)

The `add` operands (positions 5, 6) are inside branch-selector level 2's scope. A level-2 sub-cycle would scope fibre descent to positions 4-6 (the inner `oneOf`'s content). Batch zeroing at this scope would zero positions 5 and 6 together — `add(0, 0) = 0` — without the depth value or outer `div` operand in the batch.

**This DOES help**, provided the CDG correctly represents the branch-selector containment hierarchy and the scope at level 2 is narrow enough to exclude the depth value and outer values.

This is confirmed by `ChoiceDependencyGraph.build()`'s edge construction. Two edge-building rules apply:

- **Bind-inner → any node** (overlap test): any node whose `positionRange` overlaps the bind-inner's `boundRange` is added as a dependent. The branch-selectors inside the bound content have `positionRange` values within the `boundRange`, so they are dependents of the bind-inner node.
- **Branch-selector → any node** (containment test): any node whose `positionRange` is strictly contained within the branch-selector's `scopeRange` (selected subtree) is added as a dependent. The inner `oneOf`'s pick entry falls within the outer `oneOf`'s subtree, so the level-2 branch-selector depends on the level-1 branch-selector.

Together: the bind-inner (depth) is at level 0; the outer branch-selector is at level 1 (depends on the bind-inner); the inner branch-selector is at level 2 (depends on the outer). The level-ordering benefit for Calculator is structurally guaranteed by these two edge-building rules.

## CDG Rebuild After Structural Acceptance

**The CDG is NOT stable across levels.** Structural changes at level N shift position indices for all downstream content. The CDG must be rebuilt after any acceptance that changes the sequence length or structure.

The algorithm handles this by:
1. Checking for structural acceptance after each level's sub-cycle
2. If accepted: rebuild CDG, recompute levels, restart inner loop from level 0
3. If not accepted: advance to the next level

This means the outer loop is not a simple linear walk — it restarts when structural changes invalidate the position map. The cost is O(rebuilds × build_cost), where rebuilds = number of structural acceptances across all levels.

For BinaryHeap (4-8 bind levels), this could mean 4-8 CDG rebuilds. Each rebuild is O(n × log n) for n = number of CDG nodes. For typical generators with < 20 nodes, this is microseconds — negligible compared to the property invocations saved by eliminating stall cycles.

### Restart Semantics After Rebuild

After a CDG rebuild, "current level" in the old CDG has no meaning — node indices, level assignments, and position ranges all change. The restart policy is:

**Restart the inner `for level in levels` loop from level 0.** The outer `repeat` loop is NOT restarted — it continues its current iteration. This is a literal index reset: the loop variable goes back to 0, iterating the freshly rebuilt CDG's level list from the start. The stall counter resets (the structural acceptance counts as progress).

**Convergence cache behavior**: structural acceptance triggers `convergenceCache.invalidateAll()` (the existing mechanism at `ReductionState.swift:261`). The cache is fully cleared after a CDG rebuild. This means previously-converged levels do NOT benefit from cached floors — they must re-converge from scratch.

This is a deliberate correctness trade-off: the full clear avoids stale cache entries from positions that shifted during the structural change. The cache is keyed by flat sequence position, not by CDG level. After a structural acceptance that shifts positions, old entries at now-shifted positions would map to wrong values. Full invalidation eliminates this class of error.

**Level reassignment**: a CDG rebuild may assign different level indices to nodes that weren't structurally changed. A node at level 2 in the old CDG might be level 1 in the new one (if an upstream bind was deleted). Because the restart begins from level 0 with an empty convergence cache on a fresh CDG, this remapping is transparent — there are no stale entries to mis-attribute.

### Probe Cost of Restart

Re-convergence after a restart is cheaper than the initial convergence pass because the sequence VALUES at unaffected positions haven't changed — only their CDG level assignment may have shifted. The value-minimization encoders re-discover the same floors, though not in O(1):

- **Batch zero**: one probe per level. If all values at a level were already at zero, the batch succeeds immediately. If not, the batch fails and individual processing follows.
- **Binary search**: O(log domain) per position. Without the convergence cache, binary search has no memory of the prior floor — it re-runs the full search. For values already at their floors, the search finds the same floor in the same number of probes as the initial pass. For BinaryHeap with domain 0-100, this is ~7 probes per position.
- **Base descent**: O(1) per level if no deletion targets exist (span extraction returns empty).

For BinaryHeap with 4 CDG levels and ~15 value positions: restarting from level 0 after a level-2 structural acceptance costs roughly 4 batch-zero probes + 15 × 7 binary-search probes = ~109 probes per restart. Compare to the current architecture's stall cycles at ~200-2000 probes each. Even with 4 restarts per outer iteration, the overhead is ~436 probes — still well below the cost of eliminated stall cycles.

**Why the cache clear doesn't matter as much as it looks**: the batch-zero probe at the start of each level's fibre descent is the fast path. If all values at a level CAN be zero (common after the first outer iteration settles values near their floors), the batch succeeds in 1 probe and the remaining binary search is skipped. The O(log domain) cost per position only applies to values with non-zero floors, which are typically few after the first iteration.

**Caveat**: for the first outer iteration (where values haven't been minimized yet), restarts from structural changes at early levels cause real re-convergence work at ALL deeper levels. The probe cost is front-loaded in the first outer iteration and diminishes in subsequent iterations as more values reach zero.

## Kleisli Exploration in the New Architecture

**Kleisli exploration cannot be dropped.** Level ordering solves the discovery problem (which level to reduce first) but NOT the fibre searching problem (finding the optimal values within a bind's downstream).

Kleisli's `FibreCoveringEncoder` does joint search over the product space of all downstream positions. For a heap node with two children, fibre descent minimizes left then right sequentially, while Kleisli searches all (left, right) pairs jointly. This is strictly more thorough and catches non-monotone optima that sequential minimization misses.

**The sub-cycle should include a scoped exploration phase** for edges within the current level's scope:

```
run sub-cycle(positions):
    base descent    (structural)
    fibre descent   (value minimization)
    exploration     (Kleisli on edges within scope)
    redistribution  (tandem reduction)
```

The exploration phase runs on the CDG edges whose upstream falls within the current level's positions. Budget per level should be proportional to the number of edges at that level, with a minimum per-edge allocation (current default: 100 probes per edge).

## Convergence Cache Lifecycle

The convergence cache tracks per-position floor values established by fibre descent's binary search. It must be managed carefully across levels:

**Cache keying**: the convergence cache maps `[Int: ConvergedOrigin]` where `Int` is a flat sequence position. It has no concept of CDG level — entries are purely positional. This is important because CDG rebuilds may reassign level indices; the cache doesn't care about levels.

**Invalidation granularity** has two tiers:

1. **Value acceptance** (no structural change): invalidate entries within the affected bind span (`convergenceCache.invalidate(in: region.bindSpanRange)`). Positions outside the span retain their cached floors.
2. **Structural acceptance** (`structureChanged: true`): full cache clear (`convergenceCache.invalidateAll()`). This is the existing mechanism at `ReductionState.swift:261`.

Within a level walk, value-only acceptances at one level preserve convergence floors from other levels. Structural acceptances clear everything — this is the cost of the restart-from-level-0 policy. The cache re-populates as the restart visits each level.

**Between outer loop iterations** (when the full level walk completes without structural changes): the cache is NOT cleared. Positions that converged in the previous iteration remain converged. This is correct because their property landscape hasn't changed.

**Exception**: when Kleisli's guided lift sets values externally (via PRNG), those values are not in the convergence cache. Fibre descent encounters them as non-converged and processes them normally. The cross-CYCLE staleness from the current architecture (where Kleisli runs AFTER fibre descent has cached) is reduced because exploration runs WITHIN the same sub-cycle as fibre descent, at the same level.

**Limitation**: cross-bind-span staleness within a level is NOT fixed. If a level has two independent bind-inner nodes (no CDG edge between them), and exploration reduces one, the other node's downstream convergence floors may be stale — the property landscape changed globally but the cache only invalidates positions within the same bind span. This is the same limitation the current architecture has. The existing `detectStaleness` post-termination pass catches this case. It remains applicable and unchanged in the new architecture.

## Materialization Mode

Level-scoped sub-cycles use the same materialization modes as the current architecture:
- **Exact mode** for value minimization probes (fibre descent, binary search)
- **Guided mode** for bind-inner changes (Kleisli exploration, with fallback to current tree)
- **Exact mode** for structural deletion

When a bind-inner is reduced at level 0, the materializer calls `forward(newValue)` to produce the new bound content. The fallback tree provides values for the bound region until they're explicitly reduced at level 1+. This means level-1 values initially inherit from the tree (pre-reduction values that happen to satisfy the reduced parent's constraints), then get minimized by level-1's fibre descent.

For BinaryHeap: reducing root from 69 to 0 materializes children with `min: 0`. The fallback tree's child values (originally generated with `min: 69`) still satisfy `min: 0` (since 69 ≥ 0). The property check runs the full generator and evaluates `toSortedList` on the result. Whether the property fails depends on the specific tree structure — this is NOT guaranteed just because the parent was reduced.

**This is the same constraint the current Kleisli exploration faces.** Level ordering doesn't change the fundamental requirement: the property is evaluated on the full expression, not decomposed per level. What level ordering provides is:
- A deterministic order of attempts (parents first)
- Level-scoped batching (coupled child values zeroed together)
- Sequential binary search on the parent value, which is O(log N) probes — potentially cheaper than Kleisli's joint product-space search when the property IS monotone in the parent

**When isn't the property monotone in the parent?** When reducing the parent value causes the bound content to produce a different subtree structure (via PRNG re-materialization) that happens to pass the property. The fallback tree mitigates this — it provides the existing subtree values, which are known to fail. But if the parent reduction changes the generator structure (different bind-inner → different `forward()` → different generator), the fallback tree's positions may not align with the new generator's expectations. This is the same guided-mode alignment issue that affects Kleisli's lift.

**Fallback tree alignment across levels**: when level 0's Kleisli reduces a structure-controlling bind-inner (for example, `Gen.recursive`'s depth from 3 → 2), the structural acceptance updates BOTH the tree AND the fallback tree (existing mechanism: `fallbackTree = tree` on structural acceptance at `ReductionState.swift:257`). The CDG is rebuilt, the level walk restarts from level 0. Level 1's sub-cycle operates on the new tree's positions, which align with the updated fallback tree. There is no position misalignment — the fallback tree is always the tree state at the most recent structural acceptance, which is the state the rebuilt CDG was computed from.

For value-only acceptances (no structural change): the fallback tree is NOT updated (it only updates on structural changes). Level 1's sub-cycle sees the same fallback tree as level 0. This is correct — value changes don't shift positions, so the fallback tree's positions still align.

## Budget Allocation

Each level sub-cycle receives the same `phaseBudgetCeiling` (2000) per phase that the current architecture uses for full-sequence cycles. The budget is a ceiling, not an allocation — phases exhaust their work and return early. Scoped phases naturally use fewer probes because they have fewer targets.

Concrete per-phase budgets:

- **Base descent**: `phaseBudgetCeiling` (2000). For narrow scopes (1-5 deletion targets), actual usage is 10-50 probes. The ceiling is never hit for level sub-cycles in practice.
- **Fibre descent**: `phaseBudgetCeiling` (2000). For a single bind-inner value, actual usage is O(log domain_size) for binary search + 1 batch-zero probe. For a scope with 10 values, ~100-200 probes.
- **Exploration**: `edgeCount × perEdgeBudget` (current default: 100 per edge). Only edges with upstream at the current level are included.
- **Redistribution**: `phaseBudgetCeiling` (2000). Sibling groups within scope, typically 1-3 groups.

**Total budget across all levels**: for a CDG with N levels, the maximum budget per outer iteration is `N × 4 × phaseBudgetCeiling + cleanup_pass_budget`. For N=4 (BinaryHeap), this is 4 × 8000 + 8000 = 40,000 maximum. In practice, actual usage is far below the maximum because scoped phases exhaust early. A typical BinaryHeap outer iteration uses ~500-2000 actual probes across all levels — comparable to one full-sequence cycle in the current architecture.

**Comparison to current architecture**: the current architecture uses 2000 ceiling × 4 phases = 8000 maximum per cycle, with multiple cycles until stall. For BinaryHeap with ~5-8 stall cycles, the current total is ~15,000-40,000 probes. The new architecture's per-level scoping should produce comparable totals with better probe efficiency (fewer wasted probes on wrong-level positions).

### Expected-Case Profile: BinaryHeap (4 levels, binary branching)

The maximum-budget comparison above is a worst-case ceiling. The expected-case profile is more informative:

**First forward pass** (no convergence cache):

| Level | Nodes | Fibre descent | Kleisli (downstream) | Subtotal |
|-------|-------|---------------|----------------------|----------|
| 0 (root) | 1 bind-inner (range-ctl) | 1 batch + ~7 binary | 1 edge × ~100 (pre-optimizes 2 children) | ~108 |
| 1 (children) | 2 bind-inners (range-ctl) | 1 batch + ~14 binary | 2 edges × ~100 (pre-optimizes 4 grandchildren) | ~215 |
| 2 (grandchildren) | 4 bind-inners (range-ctl) | 1 batch + ~28 binary | 4 edges × ~100 (pre-optimizes 8 leaves) | ~429 |
| 3 (leaves) | 8 values | 1 batch + ~56 binary | 0 edges | ~57 |
| Cleanup | full sequence | 1 batch + ~15 (cache) | 0 | ~16 |
| **Total** | | | | **~825** |

BinaryHeap's bind-inners are range-controlling (the parent value sets `min` for children but doesn't change the number of entries). Fibre descent's binary search succeeds directly — no fingerprint trigger. For the UPSTREAM value, Kleisli adds nothing beyond what binary search found.

However, Kleisli's DOWNSTREAM search is valuable: after level 0's fibre descent reduces the root from 69 to 0, exploration searches (left, right) child pairs with `min=0`. If (0, 0) satisfies the property failure, Kleisli converges both children to 0 in one probe — and level 1's fibre descent sees them already at floor (batch zero succeeds in 1 probe). This cascading pre-optimization means Kleisli probes at level N reduce the work at level N+1.

For structure-controlling bind-inners (like `Gen.recursive` depth), Kleisli is the PRIMARY mechanism at that level (fibre descent is rolled back by the fingerprint guard). For range-controlling bind-inners, Kleisli is a SPECULATIVE optimization — the downstream will converge at its own level anyway, but Kleisli may get there faster via joint search.

### Kleisli Gating for Range-Controlling Levels

A possible optimization: skip exploration at level N if ALL edges from level N have range-controlling upstreams AND level N+1 exists. The classification uses the existing `isStructurallyConstant` field on CDG nodes (computed at build time by checking whether the bound subtree contains nested binds or picks). Structurally constant = range-controlling (the bound subtree structure is invariant under value changes). Not structurally constant = structure-controlling (value changes alter the sequence length or markers). No new property needed — the gate reads the existing field. This field is currently used only for fingerprint guard decisions; wiring it to exploration gating is a new use.

The rationale: fibre descent at level N already converged the upstream; level N+1's fibre descent will converge the downstream; Kleisli's joint downstream search adds marginal value for range-controlling binds where the fibre landscape is typically monotone.

Under this gating, the table becomes:

| Level | Nodes | Fibre descent | Kleisli | Subtotal |
|-------|-------|---------------|---------|----------|
| 0 (root) | 1 bind-inner (range-ctl) | 1 batch + ~7 binary | gated (level 1 exists) | ~8 |
| 1 (children) | 2 bind-inners (range-ctl) | 1 batch + ~14 binary | gated (level 2 exists) | ~15 |
| 2 (grandchildren) | 4 bind-inners (range-ctl) | 1 batch + ~28 binary | gated (level 3 exists) | ~29 |
| 3 (leaves) | 8 values | 1 batch + ~56 binary | 0 edges | ~57 |
| Cleanup | full sequence | 1 batch + ~15 (cache) | 0 | ~16 |
| **Total (gated)** | | | | **~125** |

The gating trades ~700 probes of speculative pre-optimization for simpler probe accounting. Whether the pre-optimization pays for itself depends on how often Kleisli's joint search finds a downstream floor that sequential binary search at the next level would also find. For monotone properties (the common case for range-controlling binds), sequential search is equally effective — the gate saves probes. For non-monotone downstream landscapes, Kleisli's joint search catches optima that sequential search misses — the gate loses quality.

**Kleisli acceptance and the convergence cache**: when Kleisli at level N accepts a probe that changes downstream positions (children go from 69 to 0), the accepted values are committed to the sequence via `runComposable`. The convergence cache does NOT gain entries for those positions — Kleisli doesn't run binary search, so no floor is recorded. However, the values themselves are preserved in the sequence. If a later structural acceptance clears the convergence cache, the Kleisli-established values survive (they're in the sequence, not the cache). Level N+1's fibre descent sees these values and converges them — batch-zero confirms (0 is already at floor), or binary search finds the floor in O(1) (value is already there). The cache clear doesn't undo Kleisli's work; it just means level N+1 does a confirmation pass instead of skipping via cache hit.

**Default recommendation**: run Kleisli ungated (the ~825 estimate). The 700 additional probes are a modest cost for the safety of catching non-monotone optima. If benchmarks show that range-controlling levels consistently waste Kleisli probes, add the gate as an optimization. The improvement claim does not depend on the gate — ~845 total probes vs the current architecture's ~1500-5000 is still a substantial win.

Probe count grows linearly with tree width at each depth. For 4 levels with binary branching, the first forward pass is ~825 probes ungated. If the first pass converges everything, the second pass is ~20 probes (batch-zero confirmations at each level). Total: ~845 probes across 2 outer iterations.

**Current architecture comparison**: BinaryHeap currently takes ~1500 invocations in the best case (from benchmark data). The current architecture's first cycle is efficient: full-sequence fibre descent processes all 15 values in one pass (~105 probes) plus Kleisli (~7 edges × 100 = ~700 probes) ≈ ~800 probes. But subsequent cycles re-discover ordering constraints empirically — fibre descent converges child values, Kleisli invalidates them by changing the parent, and the cycle repeats. The current architecture spends ~5-8 stall cycles at ~200-2000 probes each on this ordering discovery. Total: ~1500-5000 probes.

**Where the improvement comes from**: the new architecture's first forward pass (~825 ungated) is comparable to the current architecture's first cycle (~800). Both spend similar total probes on initial convergence. The gain is from **eliminating stall cycles**: parents are settled before children by construction. The current architecture's 3-7 stall cycles (wasted ordering-discovery probes at ~200-2000 each) are replaced by one structured forward pass where each level sees its parent already at its floor. Kleisli's downstream pre-optimization at each level further reduces later levels' work — cascading convergence.

**Improvement ratios** (comparing total expected probes across ALL outer iterations):

| Variant | New total | Current best (~1500) | Current worst (~5000) |
|---------|-----------|----------------------|-----------------------|
| Ungated (~825 + ~20 second pass) | ~845 | ~1.8× | ~5.9× |
| Gated (~125 + ~20 second pass) | ~145 | ~10× | ~34× |

The gated ratios assume the monotonicity assumption holds (sequential binary search at level N+1 finds the same floors as Kleisli's joint search at level N). The ungated ratios are conservative — Kleisli probes may partially pre-optimize downstream, reducing level N+1's work below the table's estimates.

For a CDG with N levels and M total positions, the per-level overhead is:
- CDG level query: O(1) (precomputed)
- Span extraction: O(scope size)
- Encoder ordering: O(encoder count) — fixed
- State updates: O(1) per acceptance

The per-level overhead is dominated by span extraction, which is O(scope size). The total overhead across all levels is O(M) — same as a single full-sequence pass.

## Covariant Depth Sweep

The current fibre descent has three parts: leaf-range value minimization, covariant depth sweep (depths 1 to maxBindDepth), and tail passes. The covariant sweep iterates ALL bind depths in a single fibre descent call, using `structureChangedOnCovariant = true` to force re-derivation of bind-dependent metadata.

In the level-scoped architecture, the covariant sweep's purpose is subsumed by the outer level walk. Values at bind depth 1 are at a deeper CDG level than values at bind depth 0 — they're processed at a later level in the walk. The level-scoped sub-cycle's fibre descent should **only process leaf-range values within the scope**, not run the covariant sweep. The covariant sweep would reach into deeper CDG levels, violating the level-scoping guarantee.

This means the level-scoped fibre descent is NOT the same as calling `runFibreDescent` with a scope range — it needs to suppress the covariant sweep.

**Resolution**: add `suppressCovariantSweep: Bool` to `PhaseConfiguration` (default `false`). Level sub-cycles set it to `true`. The existing `runFibreDescent` checks the flag at the covariant sweep's entry point and skips the sweep. This is a one-line guard — the lightest possible change to `runFibreDescent`.

**Note**: passing `depthFilter` on the incoming `ReductionContext` does NOT suppress the covariant sweep. The sweep creates its own `ReductionContext` with `depthFilter: d` for each depth iteration — it ignores the incoming context's filter. Only a flag at the sweep's entry point works.

### depthFilter Threading Through Context Creation Sites

Beyond suppressing the covariant sweep, the level sub-cycle's `depthFilter` must be threaded through all `ReductionContext` instances created within the sub-cycle. Currently, `depthFilter` is set at exactly one site (the covariant sweep at `ReductionState+FibreDescent.swift:186`). All other 15 context creation sites pass `depthFilter: nil`.

Sites that need modification for level-scoped sub-cycles:

| Site | File | Current depthFilter | Needs Change |
|------|------|---------------------|--------------|
| leafContext | FibreDescent:113 | nil | Yes — must inherit level's depthFilter |
| tailContext | FibreDescent:254 | nil | Yes — shortlex reorder and redistribution should respect depth scope |
| deletionContext | BaseDescent:207 | nil | No — deletion uses `positionRange` scoping, not depth filtering |
| branchReductionContext | BaseDescent:129 | nil | No — branch simplification operates on the branch-selector itself |
| bindInnerContext | BaseDescent:494 | nil | No — base descent's bind-inner value pass (runs in phase 1, before fibre descent). Applies value encoders to a bounding range of bind-inner positions at depth 0. Scoped by `positionRange`, not depthFilter. No overlap with fibre descent: base descent completes before fibre descent starts |
| kleisli exploration | KleisliExploration:123 | nil | No — edge selection scopes to level; see below |
| orderingContext | ReductionState:502 | nil | Yes — cost estimation must extract spans at the correct depth |

The modification is mechanical: accept `depthFilter` as a parameter to the sub-cycle entry point and propagate to each context constructor. No encoder changes needed — `ReductionContext.depthFilter` already filters span extraction via `extractFilteredSpans()`.

**Kleisli's internal contexts must NOT inherit the level's depthFilter.** `KleisliComposition` creates contexts at two internal sites (lines 151 and 237). These operate on a LIFTED sequence produced by `GeneratorLift`. The lifted sequence has its own bind structure — bind depth at a position in the lifted sequence is relative to the lift point, not the original sequence's root. Applying the original sequence's depthFilter (say, depth 0) to the lifted sequence would filter out positions at depth > 0 within the lift, which are exactly the positions Kleisli's downstream encoder needs to explore. Both internal context creation sites must pass `depthFilter: nil`.

Kleisli's level scoping is handled entirely by edge selection (by scope range), which already restricts exploration to edges whose upstream falls at the current level. The downstream encoder sees the full lifted fibre without depth filtering. This is correct and sufficient — no depthFilter threading into Kleisli internals.

**Risk for non-Kleisli contexts**: if a `ReductionContext` is created within a sub-cycle (for example, in fibre descent or redistribution) without inheriting the level's filter, it would process all depths, violating the exclusive scope guarantee. Currently, no encoder creates its own `ReductionContext` — all contexts are created by `ReductionState` and passed in. The threading is mechanical: accept `depthFilter` as a parameter to the sub-cycle entry point and propagate to each non-Kleisli context constructor.

## Inclusive vs Exclusive Scope: The Central Design Choice

The level walk must decide what "positions at this level" means. This is not cosmetic — it determines efficiency, correctness, and whether the architecture achieves its stated goals.

### Inclusive Scope (process everything in scopeRange)

Level N's sub-cycle operates on the union of its nodes' `scopeRange` values — the entire bound content, including nested bind regions at deeper levels.

**Problem**: level 0's scope covers the entire bound tree. Batch zeroing at level 0 includes child and grandchild values — identical to the current global batch. The "narrower batch" claim doesn't hold for the root level. Only the deepest levels get genuinely narrow batches.

**Problem**: level 0's fibre descent converges child positions, then level 0's exploration (Kleisli) changes the root value, invalidating those child floors via bind-span invalidation. Level 0 wasted probes converging children that were immediately invalidated by its own exploration phase. Level 1 then re-converges them — more total work than the current architecture.

### Exclusive Scope (process only this level's bind depth)

Level N's sub-cycle operates only on spans at bind depth N. Uses `depthFilter` on `ReductionContext` to restrict span extraction. Each level processes only the values at its own structural depth — not nested content.

**Benefit**: level 0's batch zeroing only batches depth-0 values (the root bind-inner and any peer values at the same depth). The batch is genuinely narrow.

**Benefit**: no wasted probes — level 0 doesn't converge child positions that Kleisli will invalidate. Children are deferred to level 1, which runs after the root is settled.

**Cost**: the phase DOES need to know it's scoped. Fibre descent must filter spans by bind depth, not just by position range. This conflicts with "phases don't know they're scoped" — but only slightly. The `depthFilter` already exists in `ReductionContext` and is used by the covariant sweep internally.

**Cost**: positions at bind depth 0 that are NOT bind-inner values (for example, values in a group that contains both a bind and some non-bind values) would need to be included at level 0. The scoping isn't purely "bind depth" — it's "values whose correctness depends on bind-inners at this CDG level."

### Resolution

**Use exclusive scope, implemented via `depthFilter`.** Each level's sub-cycle sets `depthFilter = bindDepth` for the current level's nodes. Fibre descent's span extraction (already `depthFilter`-aware via `extractFilteredSpans`) naturally restricts to the correct depth.

### Formal scopeRange Definition

Each level sub-cycle receives two scoping parameters:

- **`depthFilter: Int?`** — the bind depth of the current level's nodes. For bind-inner levels, this restricts span extraction to that depth. For branch-selector levels, this is `nil`.
- **`scopeRange: ClosedRange<Int>`** — the position range within the flat sequence. Limits which positions encoders iterate over.

Per node type:
- **Bind-inner node**: `scopeRange` = `positionRange.lowerBound ... boundRange.upperBound`. This INCLUDES the bind-inner value position itself (not just the bound content). With `depthFilter` restricting fibre descent to the bind-inner's depth, only the control value and any peer values at the same depth are processed — the bound content (at deeper depths) is filtered out. The bind-inner value must be within scopeRange for fibre descent to reach it; otherwise, range-controlling bind-inners (where fibre descent's binary search succeeds directly) would only be reachable via Kleisli, wasting the cheaper O(log N) path. **Performance note**: the wide scopeRange means span extraction iterates the full bound region to find the few positions at the target depth. For a bind-inner with 100 bound positions and depthFilter selecting 1 position, this is O(100) iteration for O(1) useful spans. The total across all levels is O(total_sequence) per level, not O(positions_at_depth). This is adequate — span extraction is microseconds — but a tighter scopeRange (just depth-filtered positions) would reduce iteration. Computing the tighter range requires the same per-position depth check that span extraction already does, so there is no net benefit from pre-narrowing.
- **Branch-selector node**: `scopeRange` = the selected branch's subtree range (from the CDG node's `scopeRange`).
- **Multiple nodes at the same level**: `scopeRange` = union of all nodes' scope ranges at this level. If the ranges are disjoint, the sub-cycle still runs as a SINGLE sub-cycle: one `computeEncoderOrdering()` call, one batch-zero probe covering all matching spans, and one pass of each encoder across all range segments. Encoder ordering does NOT reset between segments — they are part of the same level's reduction. Batch zeroing zeros all values at the shared depth simultaneously (one probe), which is the correct semantics: same-level peers should be zeroed jointly, not sequentially.

For branch-selector levels, `depthFilter = nil` BUT the position exclusion from §Branch-Selector Depth Exclusion applies: ranges owned by CDG nodes at deeper levels are excluded from fibre descent's span extraction and redistribution's sibling groups, even within the scopeRange.

**Implementation**: post-filter on `extractFilteredSpans` output. Call `extractFilteredSpans` with `depthFilter: nil` and the level's `scopeRange`, then remove spans whose `range.lowerBound` falls within any excluded range. The exclusion set is precomputed once per level sub-cycle as `[ClosedRange<Int>]` from the CDG node list. This avoids changing the `extractFilteredSpans` interface (no new parameter) and is O(excluded_count × span_count) per call — negligible for typical CDGs with < 20 nodes.

**Why `lowerBound` testing is sufficient**: spans extracted by `extractFilteredSpans` are homogeneous in span category (value, reduced, marker, and so on) and contiguous in position. Excluded ranges start at bind-inner or branch-selector entries, which have different span categories than value entries. A value span cannot begin outside an excluded range and extend into it — that would require the span to cross a category boundary (from value to bind-inner entry), which span extraction prevents. Partial overlap between a span and an excluded range is structurally impossible.

### Phase-Level Scoping Details

For base descent (structural deletion AND branch simplification): the entire base descent phase receives the level's `scopeRange`. Deletion scopes are already built per-depth by `buildDeletionScopes`; the scopeRange filters which scopes are relevant. Branch simplification (promotion, pivot) also receives the scopeRange and only operates on branch nodes within it — without this, base descent at level N could attempt to simplify branches outside the current level's scope, which belong to deeper levels. The `depthFilter` is NOT needed for base descent (it uses position-range scoping, not depth filtering), but `scopeRange` is load-bearing.

For exploration (Kleisli): edge filtering by scope range (already implemented) restricts to edges whose upstream is at the current level. This is correct — Kleisli at level N only explores level-N bind-inner values.

For the cleanup pass: uses `depthFilter = nil` (no filter) and `scopeRange = full sequence`, processing all positions. The convergence cache prevents re-processing positions that were already converged by level sub-cycles.

### CDG Level vs Bind Depth

The exclusive scope model uses bind depth, not CDG level index, as the filter. These are NOT the same:

- **Pure bind chains** (BinaryHeap): CDG level = bind depth. Mapping is exact.
- **Binds inside branches**: a bind-inner inside a `oneOf` branch is at bind depth 0 but CDG level > 0 (it depends on the branch-selector). Using CDG level as `depthFilter` would misclassify it.

**Resolution**: each CDG node stores its actual bind depth (from `BindSpanIndex.bindDepth(at: node.positionRange.lowerBound)`), not its CDG level index. The sub-cycle uses the node's bind depth as the `depthFilter`, not the level index.

Branch-selector nodes (which have no bind depth) use `depthFilter = nil` for their sub-cycle — their content spans all bind depths within their scope. This is correct because branch-selector scoping is about WHICH subtree is selected, not about bind depth.

### Mixed-Type Levels

A topological level can contain both bind-inner and branch-selector nodes simultaneously — for example, an independent bind-inner and an independent branch-selector in different parts of the tree that happen to have the same max-parent-depth. These require different `depthFilter` values: the bind-inner needs `depthFilter = bindDepth`, the branch-selector needs `depthFilter = nil` (with exclusion set).

**Resolution**: when a level contains both node types, the sub-cycle runs two fibre descent passes within the same level:

1. **Bind-inner pass**: `depthFilter = bindDepth`, `scopeRange` = union of bind-inner nodes' ranges (each node's `positionRange.lowerBound ... boundRange.upperBound`). Processes only the control values and peer values at that depth.
2. **Branch-selector pass**: `depthFilter = nil` with exclusion set, `scopeRange` = union of branch-selector nodes' scope ranges. Processes leaf values within the branch scopes.

Each pass runs its own `computeEncoderOrdering()` call with the pass's `depthFilter`. The bind-inner pass ordering uses `depthFilter = bindDepth` for cost estimation (sees only depth-N spans); the branch-selector pass ordering uses `depthFilter = nil` (sees all non-excluded spans within scope). Sharing a single ordering would use the wrong cost estimates for one of the two passes — an encoder with zero depth-N spans but many unfiltered spans would be incorrectly suppressed or promoted.

Base descent runs once with `scopeRange` = union of ALL nodes' ranges at the level (both types). This grants base descent access to the full level scope — branch simplification can operate on nested branches within the branch-selector parts, and deletion can target containers within the bind-inner parts. Kleisli also runs once on the full scope — edge selection already filters to edges with upstreams at this level. Only fibre descent, redistribution, and encoder ordering are split by node type.

**Constructability**: mixed-type levels arise from sequencing independent generators — for example, `Gen.sequence(elements: [Gen.bind(inner) { ... }, Gen.pick(a, b)])`. The bind-inner and pick produce independent CDG nodes (no edge between them) at the same topological level. This pattern is uncommon in user-written generators but can arise from combinator composition.

In practice, mixed-type levels are uncommon — they require two independent structural nodes with identical max-parent-depth but different node kinds. The typical CDG has bind-inners at one set of levels and branch-selectors at another.

### Level Assignment

`topologicalLevels()` assigns each node a level equal to `max(parent levels) + 1`, computed in a single pass over the existing topological order:

```
for nodeIndex in topologicalOrder:
    maxParentLevel = max(level[p] for p in parents(nodeIndex)) or -1
    level[nodeIndex] = maxParentLevel + 1
```

This is topological level assignment (longest path from any root), NOT BFS distance (shortest path from any root). The distinction matters for DAGs with uneven path lengths: if node D depends on B (level 1) and C (level 2), BFS distance from roots would place D at level 2 (shortest path), but topological level places D at level 3 (max parent + 1). The correctness argument — all parents resolved before the node — requires topological assignment. BFS distance can violate this by placing a node at the same level as one of its parents.

The method is named `topologicalLevels()` (not `breadthFirstLevels()`) to reflect this. The prior drafts used "breadth-first" colloquially to describe the level-by-level traversal pattern, but the level ASSIGNMENT is topological, not BFS.

## Leaf Position Definition

After exclusive scoping, leaf positions are value/reduced entries that were NOT processed by any level's depth-filtered sub-cycle. In practice: positions at bind depth 0 that are outside all bind spans, plus any positions at depths not covered by CDG nodes (unlikely in well-formed generators).

The final leaf pass uses `depthFilter = nil` and a position range covering the full sequence. The convergence cache prevents re-processing positions that were already converged by level sub-cycles — only truly untouched positions incur work.

## Deletion Scope Filtering

The current `buildDeletionScopes()` iterates ALL CDG nodes and creates deletion scopes by depth. When called from a level-scoped sub-cycle, it would produce scopes for ALL levels, not just the current one.

The level-scoped base descent needs to filter deletion scopes to the current level's scope range.

**Resolution: Option 3** — scope via `runStructuralDeletion`'s position range parameter. The deletion encoders already accept position ranges. Base descent passes the level's `scopeRange` to each encoder, and the encoders self-filter. `buildDeletionScopes` is unchanged — its internal topological scope ordering is redundant (the outer level walk already provides it) but harmless. This aligns with the "phases don't know they're scoped" principle and preserves the "all encoder implementations stay the same" claim.

Options considered and rejected:
1. Pass scope range to `buildDeletionScopes` — would require interface change to a shared method.
2. Filter scopes after construction — wasteful for deep CDGs.

## What Stays the Same

- All encoder implementations (deletion, value minimization, branch simplification, redistribution, sibling swap)
- `ReductionMaterializer` and materialization modes
- `ChoiceSequence` and `ChoiceTree` representations
- `BindSpanIndex` and span extraction
- The `SchedulingStrategy` protocol
- `AdaptiveStrategy` (remains the default for flat generators)
- Post-termination passes (humanOrderReorder, freeCoordinateProjection)
- Convergence cache and its bind-span invalidation mechanism
- `detectStaleness` post-termination pass (catches cross-bind-span staleness)

## Encoder State Across Level Sub-Cycles

Encoder instances are constructed once on `ReductionState` and reused across cycles. Each call to `start()` re-initializes their internal state (cohorts, plans, candidates). This is sufficient for most encoders — cross-sub-cycle state leakage doesn't occur.

Two pieces of state persist across sub-cycles and require attention:

### EncoderDominance

The dominance tracker records per-encoder success/failure history. If a value encoder consistently fails at a shallow level (because all depth-0 values are already minimal), dominance might suppress it at a deeper level where it would succeed on different values.

**Resolution**: `computeEncoderOrdering()` should run once per level sub-cycle, not once per cycle. This resets encoder ordering and dominance tracking for each level, ensuring shallow-level failures don't suppress deeper-level encoders. The ordering call should receive the level's `ReductionContext` (including `depthFilter`) so that `estimatedCost` extracts spans at the correct depth, maintaining the O(M) total overhead claim.

**Dominance accumulation within a sub-cycle**: dominance DOES accumulate across the phases within a single level's sub-cycle (base descent → fibre descent → redistribution). This is correct — an encoder that fails during fibre descent on THIS level's positions has no reason to be retried in redistribution on the SAME positions. Dominance is only invalidated at scope boundaries within base descent (existing behavior at `BaseDescent.swift:200`) and was previously invalidated at covariant sweep depth boundaries (suppressed in level-scoped mode). Between level sub-cycles, the `computeEncoderOrdering()` call resets everything.

**Cost of per-level ordering**: for a CDG with N levels, this means N calls to `computeEncoderOrdering()` per outer iteration instead of 1. Each call is O(encoder_count × span_extraction_at_level). The span extraction at each level is O(scope_size), not O(total_sequence). The total span extraction across all levels is O(M) — same as a single full-sequence call. The `encoder_count` is fixed at 5-6. For N=8 (deep BinaryHeap), the ordering overhead is 8 × 6 × O(scope) = O(M) total. This is negligible compared to the property invocation savings.

The alternative — resetting dominance only on CDG rebuild — risks stale dominance from a shallow level suppressing encoders at deeper levels. Since value distributions differ across levels (depth-0 values are often already minimal while depth-3 values need full binary search), per-level reset is the correct default.

**Single-value levels**: for a level with one bind-inner value (one span at the filtered depth), `estimatedCost` returns a small non-zero value for applicable encoders (ZeroValue, BinarySearchToZero, and so on — each sees one span). The ordering is meaningful: ZeroValue is cheapest (one probe), BinarySearch next. No encoder returns nil cost (which would suppress it) — nil cost means "no applicable targets," but one span IS an applicable target. The ordering does not degenerate for single-value levels.

### Reject Cache

The reject cache stores Zobrist hashes of rejected candidate sequences. A level-1 probe and a level-2 probe that produce the same candidate sequence would have the same hash. This is actually correct — there's no reason to re-try an identical candidate. Hash collisions between genuinely different candidates at different levels are negligible (64-bit hash).

## Fingerprint Guard and Bind-Inner Classification

Fibre descent uses a structural fingerprint to detect and rollback accidental structural changes during value minimization. This interacts differently with two kinds of bind-inners:

### Range-Controlling Bind-Inners

The bind-inner value controls the RANGE of downstream values, not the number of entries. Example: BinaryHeap's root value determines `min` for children. Reducing it from 69 to 0 changes what children CAN be, but the same number of children are generated. The sequence structure (entry count, markers) is unchanged. The fingerprint doesn't change.

**Level 0 fibre descent succeeds**: binary search on the root value is O(log N) probes. Each probe changes the range but not the structure. The fingerprint guard is not triggered.

### Structure-Controlling Bind-Inners

The bind-inner value controls the NUMBER of entries in the downstream. Example: `Gen.recursive`'s depth value determines how many recursive layers are generated. Reducing depth from 3 to 2 removes entries from the sequence. The fingerprint changes.

**Level 0 fibre descent is rolled back**: the fingerprint guard detects the structural change and reverts it. Only level 0's Kleisli exploration can reduce the depth (because Kleisli explicitly accepts structural changes via the checkpoint/rollback pattern).

**Impact**: level 0's sub-cycle for structure-controlling bind-inners is dominated by Kleisli exploration probes (budget: ~100 per edge), not binary search (O(log N)). The probe profile is fundamentally different from range-controlling bind-inners.

**Exploration budget adequacy**: for structure-controlling bind-inners with small domains (depth 0–4 = 5 values), Kleisli tries each upstream value and confirms property failure at the reduced depth. It does NOT need to optimize the downstream fibre — it only needs to DISCOVER which depth works. Fibre optimization at the discovered depth happens at deeper level sub-cycles. The ~100 probes per edge budget is adequate for discovery (5 upstream candidates × ~10 downstream confirmation probes). Thorough fibre search is deferred.

## Full-Sequence Cleanup Pass

After the level walk completes, a full-sequence cleanup pass runs with `depthFilter = nil` and `scopeRange = full sequence`. This serves four purposes:

1. **Uncovered positions**: values at bind depth 0 outside all bind/branch structure that no level sub-cycle processed.
2. **Cross-level joint deletions**: the antichain composition can now include nodes from ALL CDG levels. During level sub-cycles, each level's base descent only built antichains from nodes within its scope. The cleanup pass builds the antichain from the full CDG — catching multi-level joint deletions that weren't possible during the level walk.
3. **Value-driven structural opportunities**: deletions that failed during the level walk's base descent may now succeed because deeper levels' VALUE minimization (not structural changes) altered the property landscape. This is distinct from structural upward cascades handled by the restart mechanism — restarts fire on structural acceptances, not value acceptances. Concretely: level 0's base descent tries deleting a container. The deletion fails because the property checks a sum over the container's values, and the sum is non-zero. Level 1's fibre descent then zeros the child values (value change, no structural change, no restart). The cleanup pass re-attempts the container deletion — the sum is now zero, the property still fails, the deletion succeeds. This opportunity was invisible during the level walk because level 0's base descent ran BEFORE level 1's fibre descent.
4. **Cross-level redistribution**: tandem reduction across sibling groups that span multiple CDG levels.

For generators where all deletions are within-level and values don't create structural opportunities: the cleanup pass's base descent finds no new targets (the level walk already exhausted all within-level deletions). The cross-level antichain composition runs but finds nothing. Base descent finishes in O(1) — its value comes entirely from purposes 2 and 3, which are only relevant for generators with cross-level structural coupling.

The cleanup pass's fibre descent processes all positions. How much the convergence cache helps depends on whether structural acceptances occurred during the level walk:

- **No structural acceptances during the level walk**: the cache retains all floors from the level sub-cycles. Every position hits cache. The cleanup pass's fibre descent is O(1) per position (batch-zero check + cache hits). This is the common case for generators where structural minimization converges early.
- **Structural acceptance at the last level**: the cache was cleared at the structural acceptance, then re-populated by the remaining levels after the restart. Positions at levels that ran after the last restart have valid cache entries. Positions at levels before the last restart were re-converged during the restart and have valid entries (assuming no further structural changes after the restart).
- **Structural acceptances at many levels** (for example, BinaryHeap with deletion at every depth): the worst case. Each structural acceptance clears the cache. After the final restart, only the levels visited after the last structural acceptance have valid cache entries. Earlier levels' entries were re-populated during the restart. If the restart completed without further structural changes, all entries are valid. If structural changes cascaded during the restart, some entries are missing.

In practice: the cleanup pass's cost is bounded by one full-sequence fibre descent (the same cost as one cycle in the current architecture). This is at most 1× overhead over the current architecture per outer iteration, and is typically much less because the post-restart convergence leaves most positions cached.

This makes the cleanup pass load-bearing — not a fallback but a necessary complement to the level walk. The architecture is: **level-ordered scoped passes + full-sequence cleanup pass**. The cleanup pass is effectively one `AdaptiveStrategy` cycle running on the post-level-walk state.

## Calculator's Primary Improvement Mechanism

Under the hybrid scope model, Calculator's improvement comes from two mechanisms at different levels:

### Level 0 (exclusive scope, depth bind-inner)

The depth value is reduced from D to the minimum that still allows the failing structure. For structure-controlling bind-inners, this is done by Kleisli exploration (not fibre descent's binary search, due to the fingerprint guard). This removes unnecessary recursive layers — the expression shrinks from `add(add(div(...)))` to `div(...)`.

This is the **primary** improvement: structural simplification via depth reduction. It's enabled by exclusive scope at level 0 — the depth value is processed alone, without polluting the batch with downstream values.

### Level 1 (inclusive scope, branch-selector)

The outer `oneOf`'s scope includes the `div` operand AND the `add` operands. Level 1's batch zeroing zeros ALL of them: `div(0, add(0, 0))`. If all values CAN be zero simultaneously (they can — the property still fails), the batch succeeds in one probe. Level 2's narrower batch is only needed when level 1's broader batch fails due to un-zeroable values in the scope.

For the specific Calculator challenge, level 1's inclusive batch likely already handles the `add(0, 0)` case. The batch pollution problem (which motivated level-scoped batching) applies to more complex expressions where the outer scope contains values constrained by different parts of the property. For Calculator, the outer scope is simple enough that the global batch at level 1 works.

The narrative in earlier drafts overstated level 2's role. The primary win is level 0's depth reduction. The secondary win is that level 1's batch, operating on a structurally simpler expression (post-depth-reduction), is more likely to succeed than the current architecture's batch on the full-depth expression.

## What Changes

- `ChoiceDependencyGraph`: add `topologicalLevels()` method (max-parent-depth + 1 assignment, see §Level Assignment)
- `TopologicalStrategy`: rewrite to walk CDG levels with scoped sub-cycles, including exploration
- `BonsaiScheduler.dispatchPhase`: pass scope ranges to phase methods (already partially wired)
- `ReductionState`: reuse existing phase methods (`runBaseDescent`, `runFibreDescent`, `runKleisliExploration`) with scoping parameters (`scopeRange`, `depthFilter`, `suppressCovariantSweep`). No new top-level method — the `TopologicalStrategy` orchestrates per-level sub-cycles by configuring `PlannedPhase` entries with the correct `PhaseConfiguration`, and `BonsaiScheduler.dispatchPhase` passes those configurations to the existing methods
- CDG rebuild-and-restart flow: `TopologicalStrategy.phaseCompleted` detects structural acceptance (via `outcome.structuralAcceptances > 0`), sets an internal `needsRebuild` flag. Sub-cycle completion is implicit: `planFirstStage` is called once per sub-cycle (the scheduler calls it to start each cycle). When `planFirstStage` sees `needsRebuild`, it reads the fresh CDG from `state.dag`, recomputes `topologicalLevels()`, and resets the level index to 0. No phase counter needed — `planFirstStage` IS the sub-cycle boundary. The CDG itself is rebuilt by `BonsaiScheduler` as part of its existing post-acceptance state update. The convergence cache is cleared by `ReductionState`'s existing structural-acceptance handler. The strategy's restart role is purely: reset level index + recompute levels. All other state updates (CDG rebuild, cache clear, bindIndex rebuild) are handled by existing machinery
- CDG rebuild after structural acceptance within the level walk
- Fibre descent: suppress covariant sweep when scoped via `suppressCovariantSweep` flag on `PhaseConfiguration` (Option 2 from §Covariant Depth Sweep)
- Deletion scope filtering: pass level's `scopeRange` to each deletion encoder's position range parameter (Option 3 from §Deletion Scope Filtering — encoders self-filter, `buildDeletionScopes` unchanged)
- `computeEncoderOrdering()`: run per level sub-cycle, not per cycle (reset dominance tracking)

## Implementation Constraints

All new and modified code must follow:

- **`DOCUMENTATION_STYLE.md`**: every `internal` type and non-trivial method in ExhaustCore needs a `///` doc comment; use `// MARK: -` for implementation notes; US English; no Latin abbreviations; no hard line breaks in prose.
- **Google Swift Style Guide** (via `/swift-style-skill`): `UpperCamelCase` types, `lowerCamelCase` everything else; 2-space indentation; 100-column limit; K&R braces; whole-module imports; `guard` for early exits.

## Implementation Phases

The implementation is structured in 5 phases, ordered by dependency. Each phase produces testable artifacts and can be verified independently before proceeding. Phases 1-3 form the foundation; phase 4 is the orchestration; phase 5 is validation.

### Phase 1: CDG Level Computation (no reducer changes)

Add `topologicalLevels()` to `ChoiceDependencyGraph`. Add `bindDepth` property to `DependencyNode` (computed from `BindSpanIndex.bindDepth(at:)` at build time). Add `isStructurallyConstant` test coverage for range-controlling vs structure-controlling classification.

**Depends on**: nothing (pure addition to CDG).

**Deliverables**:
- `topologicalLevels() -> [[Int]]` method
- `bindDepth: Int?` stored property on `DependencyNode` (nil for branch-selectors)
- Unit tests: parent-before-child invariant, level count, node coverage, empty CDG, diamond dependency, bind-inside-branch, `isStructurallyConstant` classification (test plan items 1, 2)

**Verification**: all existing CDG tests pass. New tests pass. No reducer behavior changes — the method exists but nothing calls it yet. Include a Calculator CDG smoke test: build a CDG from a known Calculator counterexample, verify bind-inner at level 0, outer branch-selector at level 1, inner branch-selector at level 2, with edges matching the overlap/containment rules (§Calculator's CDG).

### Phase 2: Scoping Infrastructure (no orchestration changes)

Add the building blocks that the level walk will use. Each is independently testable.

**Depends on**: Phase 1 (needs `topologicalLevels()` and `bindDepth` for test fixtures).

**2a. Exclusion set computation**: pure function `exclusionRanges(forLevel:inCDG:scopeRange:) -> [ClosedRange<Int>]`. Collects ranges owned by deeper-level nodes whose ranges fall within the given `scopeRange`. The `scopeRange` parameter is required — without it, the function would return CDG-wide exclusions including ranges from sibling branches outside the current branch-selector's scope. Post-filter function `applyExclusion(spans:excluding:) -> [ChoiceSpan]`.

**2b. `suppressCovariantSweep` flag**: add `Bool` field to `PhaseConfiguration` (default `false`). Add one-line guard at the covariant sweep entry point in `runFibreDescent`.

**2c. `depthFilter` threading**: modify 3 context creation sites (`leafContext`, `tailContext`, `orderingContext`) to accept and propagate `depthFilter`. Verify Kleisli internal sites (lines 151, 237) remain `nil`.

**2d. `scopeRange` computation**: pure function `scopeRange(forLevel:nodes:bindIndex:) -> ClosedRange<Int>` with per-node-type logic and union for multi-node levels.

**Deliverables**:
- Exclusion set + post-filter functions with unit tests (test plan item 3)
- `suppressCovariantSweep` flag with integration test (test plan item 5)
- depthFilter threading with Kleisli isolation integration test (test plan item 6)
- scopeRange computation with unit tests (test plan item 11)
- `extractFilteredSpans` tests with non-nil depthFilter (test plan item 4)

**Verification**: all existing reducer tests pass (the new parameters default to the unscoped behavior). New unit tests pass. The flag, filter, and threading are wired but not yet invoked by any strategy.

### Phase 3: `PhaseConfiguration` Extension

Extend `PhaseConfiguration` to carry the scoping parameters that `TopologicalStrategy` will set.

**Depends on**: Phase 2 (the parameters being carried must exist).

**Deliverables**:
- `depthFilter: Int?` on `PhaseConfiguration`
- `exclusionRanges: [ClosedRange<Int>]?` on `PhaseConfiguration`
- `BonsaiScheduler.dispatchPhase` passes the full `PhaseConfiguration` to each phase method. Phase methods pull what they need: `runFibreDescent` already receives a `PhaseConfiguration` (it reads `clearConvergence` and `scopeRange`); adding `depthFilter`, `suppressCovariantSweep`, and `exclusionRanges` is consistent. `runBaseDescent` receives `scopeRange` from the configuration. No per-field parameter threading — the configuration object IS the parameter

**Verification**: all existing tests pass (new fields default to nil/false, producing unscoped behavior). The dispatcher is wired but `AdaptiveStrategy` never sets the new fields — behavior is identical.

### Phase 4: `TopologicalStrategy` Rewrite

Replace the current per-node walking with per-level walking. This is the core orchestration change.

**Depends on**: Phases 1-3 (level computation, scoping infrastructure, configuration plumbing).

**4a. Level walk state machine**: rewrite `planFirstStage`/`planSecondStage` to iterate `topologicalLevels()`. Each level produces `PlannedPhase` entries with the correct `PhaseConfiguration` (depthFilter, scopeRange, suppressCovariantSweep, exclusionRanges). Cleanup pass follows the level walk.

**4b. Rebuild-and-restart**: `phaseCompleted` detects structural acceptance, sets `needsRebuild`. Next `planFirstStage` reads the fresh DAG, recomputes levels, resets level index to 0.

**4c. Mixed-type level handling**: when a level contains both bind-inner and branch-selector nodes, produce two fibre descent `PlannedPhase` entries with per-type configurations.

**4d. `computeEncoderOrdering()` per level**: call at the start of each level's sub-cycle (or per fibre descent pass for mixed-type levels).

**Deliverables**:
- Rewritten `TopologicalStrategy` conforming to `SchedulingStrategy`
- Unit tests on strategy output: `PlannedPhase` inspection for scope parameters (test plan item 8, layer 1)
- Integration tests via `BonsaiScheduler`: level walk order, restart, stall counting, flat generator fallback (test plan item 8, layer 2)
- `computeEncoderOrdering()` per-level reset integration test (test plan item 7)
- Mixed-type level integration test (test plan item 10)

**Verification**: flat generators (Bound5, Deletion, Difference, Distinct, Reverse) produce identical results with `.topological` and `.adaptive`. Bind generators (BinaryHeap, Calculator) produce results — correctness TBD in Phase 5.

### Phase 5: Validation and Benchmarking

Run the full benchmark suite and shrinking challenges. Compare against adaptive.

**Depends on**: Phase 4.

**Deliverables**:
- Benchmark comparison: invocation counts, timing, CE counts for all challenges with both strategies
- Calculator reduction test: verify `add(-6, 6)` → `add(0, 0)` via the topological strategy (CDG structure already verified in Phase 1)
- BinaryHeap: verify invocation count drops relative to adaptive
- Convergence cache cross-level lifecycle integration tests (test plan item 9, including `detectStaleness`)
- Regression check: no flat-generator test produces different results with `.topological` vs `.adaptive`

**Output canonicality**: the topological strategy may reach different local minima than the adaptive strategy. Two counterexamples that are both shortlex-minimal and both fail the property are equally correct. Shrinking challenge tests that assert a specific counterexample value may need updating if the topological strategy finds a different-but-equally-minimal result. Tests should be structured to assert structural properties (shortlex-minimal, property fails) rather than exact output values, except where the minimal counterexample is provably unique (for example, Bound5 where the minimum is always `[0, 0, 0, 0, 0]`).

**Verification**: all existing shrinking challenge tests pass with `.topological` (updating exact-value assertions where the strategy finds an equally-minimal alternative). Benchmark numbers match or improve on adaptive for bind generators. Flat generators produce identical results (single cleanup pass = same as adaptive).

### Dependency Graph

```
Phase 1 (CDG levels)
    ↓
Phase 2 (scoping infrastructure)
    ↓
Phase 3 (PhaseConfiguration extension)
    ↓
Phase 4 (TopologicalStrategy rewrite)
    ↓
Phase 5 (validation)
```

Phases 2a-2d are independent of each other and can be implemented in parallel. Phase 3 is a thin wiring layer. Phase 4 is the only phase that changes observable reduction behavior — all prior phases add infrastructure that defaults to the unscoped path.

## CDG Shape Classification

| CDG Shape | Example | Level Benefit |
|---|---|---|
| No nodes (flat) | Bound5, Deletion, Difference, Reverse | None — single leaf pass, identical to adaptive |
| Bind-inner chain | BinaryHeap (parent → child → grandchild) | High — parent-first ordering eliminates stall cycles |
| Branch-selector chain | Calculator without Gen.recursive | Moderate — depth-first expression traversal, scoped batching |
| Mixed bind + branch | Calculator with Gen.recursive | High — bind-inner depth at level 0, branches at deeper levels |
| Independent peers | Bound5's five arrays (all at same level) | None — single level contains everything, same as global batch |
| Wide independent binds | StructuralPathological's wide CDG | Low — all nodes at the same level means one sub-cycle + cleanup, structurally identical to adaptive. Benefit exists only if nodes have downstream bound content (level walk settles bind-inners before processing downstream). If all nodes are leaf-level with no downstream, benefit is zero. |

## Cross-Level Coordination

### Joint Bind-Inner Reduction

The current base descent includes joint bind-inner reduction (`ProductSpaceBatchEncoder`, `ProductSpaceAdaptiveEncoder`) which tries reducing multiple bind-inner values simultaneously. In the level-scoped architecture, this is restricted to bind-inners within the current level — nodes at the same CDG level.

For bind-inners in a dependency chain (A at level 0, B at level 1), joint reduction is unnecessary — A is reduced first, then B. The level ordering provides the coordination.

For independent bind-inners at the same level (two root binds), joint reduction still operates normally — both are within the same level's scope.

The antichain composition (`AntichainDeletionEncoder`) builds its antichain from CDG nodes. Level-scoped deletion builds the antichain from nodes within the level's scope, which may miss antichain members at other levels. This reduces the antichain's power for multi-level joint deletion. The cleanup pass builds the antichain from the full CDG and can catch cross-level antichains that the level walk missed.

**Theoretical bound on antichain power loss**: there is no clean theoretical bound. The antichain's effectiveness depends on the generator structure and property in ways that don't decompose analytically. For generators where the optimal shrink is a joint deletion of nodes at k different CDG levels, the level-scoped antichain misses it during the level walk; the cleanup pass may or may not recover it depending on whether the positions are still available post-level-walk. For generators where the optimal shrink is within a single level (the common case for bind-inner chains), the level-scoped antichain is at full power. The current architecture's antichain operates on the full CDG with a limited beam width, so it also doesn't guarantee finding the optimal cross-level antichain. This is strictly an empirical question — the benchmark suite should compare antichain hit rates between the two architectures.

### Upward Cascades

Level ordering is optimized for **downward cascades** (parent → child). Reducing a parent enables child reduction at the next level — discovered immediately by the forward walk.

Upward cascades come in two varieties with different latencies:

**Structural upward cascades** (child structural change → parent structural deletion becomes viable): handled within the SAME outer iteration via the restart mechanism. When a deep level's base descent accepts a structural change (for example, simplifying a nested bind region), the CDG is rebuilt and the inner loop restarts from level 0. The parent level re-runs base descent on the simplified structure — the deletion that previously failed now succeeds. Cost: one restart, not one full outer iteration.

**Value upward cascades** (child value change → parent value reduction becomes possible): require one additional outer iteration. The parent level's convergence floors were established during the current forward pass. The child's value change at a deeper level may change the property landscape for the parent, but the parent's sub-cycle already ran. The benefit is discovered on the next forward pass when the parent level's fibre descent re-runs and finds a new floor.

The current architecture handles value upward cascades within a single cycle — fibre descent processes all positions, so a child change is immediately visible to parent positions in the same pass. The new architecture delays this by up to one forward pass. For most generators, this is negligible — value upward cascades are rare compared to downward cascades (parent-first ordering is the natural reduction direction for bind-dependent generators).

**Example**: Calculator's `add(0, 0)` — reducing the add operands to 0 is a bottom-up effect (inner values enable the outer div to fail). In the exclusive-scope model, level 2 reduces the add operands. The outer div operand at level 1 was already reduced. The upward effect (add evaluating to 0) is visible to the property check at level 2's sub-cycle — because the property always evaluates the full expression. So the upward cascade is handled WITHIN the level-2 sub-cycle, not across iterations. The property is global; only the ENCODER scoping is per-level.

This is a crucial distinction: the encoder only modifies positions at its level, but the property check evaluates the FULL expression. Reducing add(X, Y) to add(0, 0) at level 2 still checks div(0, add(0, 0)) — the full expression. The upward cascade is captured by the property evaluation, not by cross-level encoder coordination.

### Same-Level Product Space

Two bind-inners at the same CDG level whose bound generators share structure (for example, two array-length controls for arrays of the same element type) present a product-space opportunity: joint value changes that exploit the shared structure. In the fibration framework (§Categorical Perspective), this corresponds to a natural transformation between the two fibers.

Neither the current architecture nor the new one exploits this. Both process same-level bind-inners independently within fibre descent. Joint bind-inner reduction (`ProductSpaceBatchEncoder`) handles coordinated STRUCTURAL changes but not coordinated VALUE changes across same-level peers.

This is a gap, but it's unchanged from the current architecture. A product-space treatment for same-level value minimization would require:
1. Detecting shared fiber structure (analysis at CDG build time)
2. Joint binary search or joint batch zeroing across the peer bind-inners
3. Proof that the joint search space is small enough to justify the extra probes

This is deferred as a potential future enhancement. The benchmark suite should measure whether same-level peer bind-inners are common enough to warrant the complexity.

## Risks

- **CDG rebuild cost**: O(rebuilds × n log n) for CDG construction, plus ~109 probes per restart for re-convergence (§Probe Cost of Restart). For generators with many structural acceptances, the restart overhead is front-loaded in the first outer iteration. Mitigated by the small number of CDG nodes in practice (< 20), the batch-zero fast path (O(1) per level when values are already at zero), and diminishing cost in later iterations.
- **Convergence cache full clear on structural acceptance**: every structural acceptance clears the entire convergence cache, even for positions unaffected by the change. This is the price of correctness (avoiding stale entries at shifted positions). The worst case — structural acceptances at every level — costs one full-sequence re-convergence per restart. Mitigated by the cleanup pass's cache re-population and by structural acceptances typically concentrating at early levels.
- **Inter-level property coupling**: values at different CDG levels coupled by the property (not by bind structure) are partially handled by full-expression property evaluation. True cross-level encoder coordination (modifying positions at two different levels simultaneously) is a gap — same as the current architecture.
- **Branch-selector depth exclusion complexity**: branch-selector sub-cycles must exclude positions belonging to deeper bind-inner CDG nodes (§Branch-Selector Depth Exclusion). The exclusion set computation is cheap (CDG node list filtered by level and range) but adds a new code path that must be tested for edge cases (nested branches containing branches, empty exclusion sets, and so on).
- **depthFilter threading**: 3 `ReductionContext` creation sites need modification to inherit the level's depthFilter (`leafContext`, `tailContext`, `orderingContext` — see §depthFilter Threading table). 2 Kleisli internal sites must explicitly NOT inherit it. 2 others (`deletionContext`, `branchReductionContext`) are unchanged. Missing a site would cause the sub-cycle to process all depths, violating the exclusive scope guarantee. This is a mechanical change but requires careful auditing.
- **Budget imbalance**: each level sub-cycle receives the same phase ceiling (2000). For deep CDGs (8+ levels), the total maximum budget is 8× the current per-cycle budget. Actual usage is much less (scoped phases exhaust early), but worst-case total probes could exceed the current architecture if many levels have non-trivial work. Needs empirical monitoring.
- **Antichain power reduction**: level-scoped antichain composition loses members from other levels. Cross-level joint deletion is less thorough during the level walk. The cleanup pass partially recovers this. No theoretical bound on the loss — empirical question.
- **Value upward cascades**: the level walk delays value upward cascades by one forward pass compared to the current architecture's within-cycle propagation. Structural upward cascades are handled within the same iteration via restart. For generators with frequent value upward cascades, the new architecture may need one additional forward pass per cascade chain.

## Categorical Perspective

The current reduction architecture is grounded in the S-J algebra / Grothendieck opfibration framework: the choice sequence lives in a total category with a grade monoid, the solution functor S: Σ^op → Set maps each sequence to its property-failure witnesses, and 2-cell dominance orders the encoder algebra. The CDG encodes the fibration structure — each bind-inner defines a fiber over its value, and dependents live in fibers over fibers.

The level walk corresponds to a **stratified descent through the tower of fibrations** induced by the CDG's dependency order. Rather than searching the global morphism space Hom(σ, τ) directly (which is what the current full-sequence phases do), the level walk decomposes it along the fiber tower:

```
Hom(σ, τ) ≈ Hom₀(σ₀, τ₀) × Hom₁(σ₁(τ₀), τ₁) × ... × Homₙ(σₙ(parents(n)), τₙ)
```

where Homₖ is the local morphism space at fiber level k, and each level's Homₖ may itself be a product over the nodes at that level: Homₖ = ∏ᵢ Homₖⁱ. The conditioning σₖ(parents(k)) reflects the CDG's DAG structure — a node at level 2 with two parents at level 1 conditions on the product τ₁ᵃ × τ₁ᵇ of both parents' resolved targets. Each level's sub-cycle searches Homₖ (the product of its node searches), and the outer loop composes the local solutions.

This factorization holds for DAGs, not just chains. Diamond shapes (a node at level 2 depending on two nodes at level 1) are handled because both parent nodes are resolved at level 1 BEFORE the level-2 node's sub-cycle runs. The product τ₁ᵃ × τ₁ᵇ is a single conditioning object. The CDG's topological level assignment guarantees that all parents of a level-k node are at levels < k, so their targets are known when level k's sub-cycle begins. This is the same decomposition structure as Bayesian network factorization: P(X₁, ..., Xₙ) = ∏ᵢ P(Xᵢ | parents(Xᵢ)).

The correctness argument is operational, not categorical: convergence follows from the stall-detection termination condition and the monotonicity of committed state. Each sub-cycle can only improve or stall — every accepted probe produces a sequence strictly shortlex-smaller than the pre-probe state. This is enforced by `runComposable`'s acceptance check, which compares the full candidate sequence against the current sequence under the shortlex ordering and rejects non-improvements.

**Kleisli qualification**: Kleisli's guided lift uses PRNG to fill positions not determined by the lift, producing intermediate candidates with potentially LARGER values at those positions. The search process is non-monotone. But the acceptance gate ensures that committed state is monotone: a Kleisli probe is accepted only if the FULL post-lift sequence (intended changes + PRNG collateral) is shortlex-smaller than the current state. The PRNG introduces exploration noise, not committed regression. This guarantee is unchanged in the level-scoped architecture — `runComposable` is the same.

The categorical grounding motivates the decomposition but does not provide a completeness guarantee — the product of local optima is not guaranteed to be globally optimal. The cleanup pass and outer loop iterations serve as corrections for this gap.

For same-level peer nodes (two bind-inners at the same CDG level), the fibers are independent: Homₖ = Homₖᵃ × Homₖᵇ. The level walk searches each factor independently. If the fibers share structure (a natural transformation between them), a product-space search over the diagonal could find joint optima missed by independent search. This is the same gap described in §Same-Level Product Space — categorical structure that the algorithm does not exploit.

## Verification

1. **Calculator**: `add(-6, 6)` → `add(0, 0)` via level-scoped batch zeroing at the branch-selector level containing the `add` operands. CDG structure verified by unit test in Phase 1 (bind-inner at level 0, outer branch-selector at level 1, inner branch-selector at level 2). This verification item tests the reduction OUTCOME — that the topological strategy produces `add(0, 0)` from a known counterexample.
2. **BinaryHeap**: parent-first ordering reduces stall cycles. Verify invocation count drops.
3. **Coupling**: bind-dependent generator — level ordering reduces controlling value before dependent array.
4. **Flat generators** (Bound5, Deletion, Difference, Distinct, Reverse, etc.): identical to adaptive — single leaf pass.
5. **Benchmark suite**: compare invocation counts, timing, and CE counts against both adaptive and current topological.
6. **CDG rebuild correctness**: verify position ranges remain valid after structural acceptance within the level walk.
7. **Branch-selector depth exclusion**: test with a generator producing nested branches containing bind-inners (for example, `oneOf` wrapping a `bind`). Verify that fibre descent at the branch-selector level does NOT process the nested bind-inner's value or bound content. Verify that an empty exclusion set (branch-selector with no deeper CDG nodes in scope) produces identical behavior to the unscoped path. Verify that redistribution respects the same exclusion.
8. **Mixed-type levels**: construct a generator with an independent bind and pick at the same level (for example, `Gen.sequence(elements: [Gen.bind(inner) { ... }, Gen.pick(a, b)])`). Verify that the bind-inner fibre descent pass uses `depthFilter = bindDepth` and the branch-selector pass uses `depthFilter = nil` with the exclusion set. Verify each pass runs its own `computeEncoderOrdering()`. Verify base descent runs once on the full union scope.

## Test Plan

The implementation introduces 10 new or changed components. Four form the scoping foundation (`topologicalLevels`, node bind depth, exclusion set, depthFilter threading) — if any is wrong, the exclusive scope model breaks silently. All four are pure-function computations amenable to unit testing from synthetic CDG structures, following the established pattern in `ChoiceDependencyGraphTests.swift`.

### Priority

| Priority | Components |
|----------|------------|
| Critical | `topologicalLevels()`, CDG node bind depth, branch-selector depth exclusion, depthFilter threading (7 sites audited, 3 changed), `TopologicalStrategy` level walk |
| High | `extractFilteredSpans` with depthFilter, covariant sweep suppression, convergence cache cross-level lifecycle (including `detectStaleness`), scopeRange computation, mixed-type level two-pass fibre descent |
| Medium | `computeEncoderOrdering()` per level (affects efficiency, not correctness) |

### 1. `topologicalLevels()` — unit tests

Foundational computation. Every other component depends on correct level assignment. Existing CDG test suite (`ChoiceDependencyGraphTests.swift`, 14 tests) covers `build()`, topological order, structural constancy, fingerprints, and edge construction using synthetic trees.

Tests:

- **Parent-before-child invariant**: for every node at level k, ALL its dependencies must be at levels < k. Test with: nested binds (chain), branch-inside-bind (mixed), diamond shapes (node with two parents at different depths), independent peers (both at level 0).
- **Level count matches CDG depth**: for a chain of N nested binds, `topologicalLevels()` returns exactly N levels. For independent binds, 1 level.
- **Node coverage**: every node appears in exactly one level. No node missing, no node duplicated.
- **Empty CDG**: no nodes → no levels (returns `[]`). The existing `noBindsNoBranches` test fixture can be reused.
- **Diamond dependency**: a node depending on two parents at different levels is at `max(parentLevel) + 1`. Requires a new fixture (for example, a bind whose bound content contains two branches that both feed into a deeper bind).
- **Bind-inside-branch**: the `branchInsideBind` fixture has a bind-inner at level 0 and a branch-selector at level 1. `topologicalLevels()` should place the branch at level 1. A bind INSIDE a branch is at CDG level > 0 but bind depth 0 — exercises the level-vs-depth distinction.
- **`isStructurallyConstant` classification**: verify the field is correct for both range-controlling (BinaryHeap: bound subtree structure invariant under value changes → `true`) and structure-controlling (`Gen.recursive`: value changes alter entry count → `false`) bind-inners. This field is currently used for fingerprint guard decisions and is identified as the mechanism for a future Kleisli gate (§Kleisli Gating). Testing it now in the CDG context prevents a latent gap if the gate is later implemented. The existing CDG tests (`ChoiceDependencyGraphTests.swift`) test structural constancy but not specifically for these two bind-inner categories.

Testability: pure function of CDG node/edge structure. Direct unit tests from synthetic trees.

### 2. CDG Node Bind Depth — unit tests

Each CDG node carries its actual bind depth (`BindSpanIndex.bindDepth(at: node.positionRange.lowerBound)`), used to set `depthFilter`. Existing `BindSpanIndex` tests cover `bindDepth(at:)` in isolation. CDG tests don't verify bind depth on nodes.

Tests:

- **Bind depth matches BindSpanIndex**: for each node in a CDG built from a nested-bind tree, `node.bindDepth` equals `BindSpanIndex.bindDepth(at: node.positionRange.lowerBound)`.
- **Bind-inside-branch**: a bind-inner inside a branch has CDG level > 0 but bind depth 0. The stored bind depth must be 0.
- **Branch-selector bind depth**: branch-selector nodes store `nil` (they use `depthFilter = nil`).

Testability: same synthetic-tree approach as CDG tests.

### 3. Branch-Selector Depth Exclusion — unit tests

Entirely new logic. Computes an exclusion set of position ranges belonging to deeper-level CDG nodes. No existing mechanism in the codebase.

Tests:

- **Bind-inner exclusion range**: for a bind-inner at level N+1 inside a branch-selector's scope, the excluded range is `positionRange.lowerBound ... boundRange.upperBound`. Both the control value AND the bound content are excluded.
- **Branch-selector exclusion range**: for a nested branch-selector at level N+1, only the `positionRange` (pick entry) is excluded, not the entire subtree.
- **Empty exclusion**: a branch-selector with no deeper CDG nodes in its scope produces an empty exclusion set.
- **Exclusion completeness**: a branch containing two bind-inners at different deeper levels has both excluded.
- **Post-filter on spans**: after `extractFilteredSpans`, apply the exclusion filter. Verify spans at excluded positions are removed; spans at non-excluded positions are retained. Existing `SpanExtractionTests.swift` (54 tests) provides the baseline.
- **Exclusion does NOT affect base descent**: base descent receives the full scope. Only fibre descent and redistribution see the exclusion.

Testability: the exclusion set computation is a pure function (CDG + level + scope range → `[ClosedRange<Int>]`). The post-filter on spans is a pure function (spans + exclusion set → filtered spans). Both are unit-testable without the full reducer.

### 4. `extractFilteredSpans` with depthFilter — unit tests

Already filters by `depthFilter` when set. The new architecture threads `depthFilter` through sites that currently pass `nil`. Existing `SpanExtractionTests.swift` has 54 tests but none target the `depthFilter` path specifically.

Tests:

- **depthFilter filters correctly**: sequence with values at bind depths 0, 1, 2. Extract with `depthFilter = 1`. Only depth-1 spans returned.
- **depthFilter = nil returns all**: same sequence, `depthFilter = nil` returns spans at all depths.
- **depthFilter with empty result**: `depthFilter = 3` on a sequence with max bind depth 2 returns empty.
- **depthFilter + position range**: both filters apply simultaneously. A span at depth 1 outside the position range is excluded. A span at depth 0 inside the position range is excluded by `depthFilter`.

Testability: `extractFilteredSpans` is a static method. Fully unit-testable.

### 5. Covariant Sweep Suppression — integration tests

`suppressCovariantSweep` flag on `PhaseConfiguration`. No existing tests verify whether the sweep runs.

Tests:

- **Flag suppresses sweep**: with `suppressCovariantSweep = true`, fibre descent processes only leaf-range spans (no depth > 0 sweeps). Verify via convergence cache entries: depth-0 positions have entries, depth-1+ positions do not.
- **Flag absent enables sweep**: without the flag, the covariant sweep runs normally. Depth-1+ positions have convergence cache entries.
- **Cleanup pass has no suppression**: the cleanup pass runs with `suppressCovariantSweep = false`. All depths processed.

Testability: moderate. Requires observing which positions were probed. Convergence cache entries post-fibre-descent are the most practical observable: sweep-processed positions have entries, suppressed positions do not.

### 6. depthFilter Threading (7 sites audited, 3 changed) — unit + integration tests

The threading table (§depthFilter Threading) lists 7 `ReductionContext` creation sites. 3 must inherit the level's `depthFilter` (`leafContext`, `tailContext`, `orderingContext`). 2 Kleisli internal sites must explicitly NOT inherit it. 2 others (`deletionContext`, `branchReductionContext`) are unchanged.

Tests:

- **leafContext inherits**: fibre descent with `depthFilter = 1` extracts only depth-1 spans in the leaf-range pass.
- **tailContext inherits**: shortlex reorder and tandem reduction operate only on depth-filtered spans.
- **orderingContext inherits**: `computeEncoderOrdering()` estimates cost using only depth-filtered spans.
- **Kleisli internal contexts do NOT inherit**: construct a `KleisliComposition` where the lifted fibre has positions at depth > 0. Pass an outer context with `depthFilter = 0`. Verify the downstream encoder's `start()` receives a context with `depthFilter = nil` and explores all positions.

The Kleisli isolation test is the most important — a bug here silently breaks downstream search at every level.

Testability approach (committed): integration test via `BonsaiScheduler` with the topological strategy. Construct a bind generator where the lifted fibre has values at depth > 0. Run reduction with `depthFilter = 0` at the bind-inner's level. Verify that Kleisli's downstream encoder DOES explore depth-1+ positions (observable via invocation count or converged values in the result). If the downstream encoder incorrectly inherited `depthFilter = 0`, it would skip depth-1+ positions and leave them at their initial values — a detectable regression in the output sequence.

This avoids extracting context construction into testable functions (which would add API surface for test-only purposes). The integration test is more robust — it tests the full path from strategy through scheduler to Kleisli to downstream encoder.

### 7. `computeEncoderOrdering()` Per Level �� unit tests

Changed from once per cycle to once per level sub-cycle. Resets dominance and uses the level's `depthFilter` for cost estimation.

Tests:

- **Per-level reset clears dominance**: an encoder suppressed by dominance at level 0 is not suppressed at level 1. Run two sub-cycles: one where the encoder has no targets (suppressed), one where it does.
- **Cost estimation uses depthFilter**: at a level with `depthFilter = 1` and 3 depth-1 spans, cost estimation returns a value proportional to 3, not total span count.
- **Single-value levels**: one bind-inner (one span), all applicable encoders return small positive costs. No encoder suppressed.

Testability approach (committed): integration test observing whether a specific encoder runs at a deeper level. Consistent with the principle of avoiding test-only API surface (applied in §depthFilter Threading for the Kleisli isolation test). The `probeRecorder` callback (if added for test plan item 8) would also serve here — recording which encoder produced each probe at each level.

### 8. `TopologicalStrategy` Level Walk — integration tests

Core orchestration rewrite. No existing unit tests for `TopologicalStrategy`. `BonsaiSchedulerTests.swift` (7 tests) covers `AdaptiveStrategy` integration. Shrinking challenges are end-to-end.

Tests:

- **Level walk visits all levels in order**: CDG with 3 levels → sub-cycles for levels 0, 1, 2 in order, then cleanup.
- **Inner restart on structural acceptance**: simulate structural acceptance at level 1. Walk restarts from level 0.
- **CDG rebuild before restart**: after structural acceptance, CDG is rebuilt before restarting.
- **Outer stall counting**: complete forward pass with zero acceptances increments stall counter. Any acceptance resets it.
- **Cleanup pass always runs**: even if all levels stall.
- **Flat generator → single cleanup pass**: CDG with no nodes, only the cleanup pass runs.
- **Scope parameters per level**: each sub-cycle receives the correct `depthFilter` and `scopeRange`. Two-layer observable: (1) **unit test on strategy output**: call `planFirstStage`/`planSecondStage` on `TopologicalStrategy` with a mock `ReductionStateView` that reports a known CDG. Inspect the returned `PlannedPhase` entries' `PhaseConfiguration` for correct `scopeRange` and `depthFilter`. This directly tests the strategy's scoping decisions without running the full reducer. (2) **integration test on intermediate state**: the property closure receives the materialized output value, but the test needs to observe which POSITIONS were probed. The existing `isInstrumented` flag on `ReductionState` enables `ExhaustLog.debug` events with position metadata. The integration test captures log events during the level-0 sub-cycle and verifies that probed positions are within the expected depth-0 set. No new test infrastructure needed — the instrumentation path exists. If finer-grained observation is needed, a test-only `probeRecorder` callback on `BonsaiScheduler` (recording `(phase, position, accepted)` tuples) is a small addition that would also serve test plan items 5 and 10.

Most practical approach: layer (1) is a direct unit test on `TopologicalStrategy` — fast, deterministic, no reducer. Layer (2) is a `BonsaiSchedulerTests`-style integration test with an instrumented property — slower but tests the full dispatch path. Both layers are needed: layer (1) catches strategy logic errors; layer (2) catches wiring errors between strategy and dispatcher. For restart and stall-counting tests, the strategy's `phaseCompleted` callback drives state transitions — a mock that reports structural acceptance vs value acceptance vs stall exercises each path. Shrinking challenges provide regression coverage but not targeted path coverage.

### 9. Convergence Cache Cross-Level Lifecycle — integration tests

The cache itself is well-tested (16 unit tests in `ConvergenceCacheTests.swift`). The new invariants are about lifecycle across the level walk.

Tests:

- **Value acceptance preserves cross-level entries**: level 0 populates entries. Level 0's value acceptance invalidates its bind span. Level 1 sees entries outside that span as cached.
- **Structural acceptance clears everything**: level 0 populates entries. Level 1's structural acceptance calls `invalidateAll()`. Level 0's re-run sees empty cache.
- **Re-population after restart**: after `invalidateAll()`, each level's fibre descent repopulates entries. Verify entries exist for all levels after restart completes.
- **Cache persists across outer iterations**: after a complete forward pass with no structural changes, the next pass starts with cache intact.
- **`detectStaleness` fires for cross-bind-span staleness**: construct a level with two independent bind-inner nodes (no CDG edge between them). Kleisli at one node reduces its downstream, changing the property landscape globally. The other node's convergence floors are stale (the cache only invalidated within the first node's bind span). After the level walk and cleanup pass complete, the post-termination `detectStaleness` pass detects the stale entries and re-converges. This is the §Convergence Cache Lifecycle "Limitation" — the new architecture inherits it unchanged, but Kleisli now runs within the sub-cycle rather than as a separate post-fibre-descent phase, which could change the timing of the staleness.

Testability: cache itself is unit-testable. Lifecycle across the level walk requires scheduler integration. The `detectStaleness` test requires a generator with two independent bind-inners where Kleisli at one affects the property landscape for the other — constructable as `Gen.sequence(elements: [Gen.bind(a) { ... }, Gen.bind(b) { ... }])` with a property that couples their outputs.

### 10. Mixed-Type Level Two-Pass Fibre Descent — integration tests

New logic with no counterpart in the current codebase. When a level contains both bind-inner and branch-selector nodes, fibre descent and redistribution run two passes with different `depthFilter` values and separate `computeEncoderOrdering()` calls.

Tests:

- **Two-pass execution**: construct a generator producing a mixed-type level (`Gen.sequence(elements: [Gen.bind(inner) { ... }, Gen.pick(a, b)])`). Verify that fibre descent runs twice — once with `depthFilter = bindDepth`, once with `depthFilter = nil` + exclusion set. Observable: convergence cache entries at both the bind-inner's depth and the branch-selector's leaf depth.
- **Separate encoder ordering per pass**: the bind-inner pass and branch-selector pass compute independent orderings. Test: construct a mixed level where the bind-inner has one span at depth 1 (so `BinarySearchToZero` is cheapest) and the branch-selector has 10 spans at depth 0 (so `ZeroValue` is cheapest). If a shared ordering with `depthFilter = nil` ran, it would see all 11 spans and choose `ZeroValue` first for both passes. With separate orderings, the bind-inner pass should choose `BinarySearchToZero` first (one depth-1 span) and the branch-selector pass should choose `ZeroValue` first (10 depth-0 spans). Observable: check the encoder execution order per pass — the bind-inner pass's first accepted probe comes from `BinarySearchToZero`, not `ZeroValue`. A shared-ordering false negative is impossible under this fixture because the ordering differs between the two depthFilter configurations.
- **Shared base descent**: base descent runs once on the full union scope. Branch simplification within the branch-selector part AND deletion within the bind-inner part both execute. Observable: structural changes from both node types are accepted.
- **Single-type level is not affected**: a level with only bind-inner nodes runs a single fibre descent pass (no two-pass splitting). Verify by checking that fibre descent is called once, not twice.

Testability: requires scheduler integration with a mixed-type-level generator. The observable is convergence cache state and final sequence values. Construction: `Gen.sequence(elements: [Gen.bind(...), Gen.pick(...)])` with independent subtrees.

### 11. Formal scopeRange Computation — unit tests

How `scopeRange` is computed per node type and for multi-node levels.

Tests:

- **Bind-inner includes control value**: bind with inner at position 5 and bound range 6-20 → `scopeRange` is `5...20`.
- **Branch-selector is subtree range**: from the CDG node's `scopeRange` field.
- **Multi-node union**: two independent bind-inners at level 0 with scopes `[1...10]` and `[15...25]` produce a union covering both.
- **Disjoint ranges single batch**: batch zeroing operates on all matching spans across both range segments in one probe.

Testability: pure function of CDG nodes and level assignment. Fully unit-testable.
