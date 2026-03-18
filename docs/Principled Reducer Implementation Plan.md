# Implementation Plan: Principled Bind-Aware Reducer

Implementation plan for the architecture described in
"Principled Bind-Aware Test Case Reduction for Exhaust" (v2).

The plan is structured as a sequence of independently shippable milestones.
Each milestone adds value on its own and is testable in isolation. The
BonsaiReducer remains the default until the new scheduler passes the full
test suite, at which point it replaces the BonsaiReducer behind the same
`.useBonsaiReducer` configuration flag.

---

## Milestone 0: Infrastructure (no behaviour change)

### 0a. DependencyDAG

New file: `Sources/ExhaustCore/Interpreters/Reduction/DependencyDAG.swift`

**Types:**

```swift
enum PositionClassification {
    case structural(StructuralKind)
    case leaf

    enum StructuralKind {
        case bindInner(regionIndex: Int)
        case branchSelector
    }
}

struct DependencyNode {
    let positionRange: ClosedRange<Int>
    let kind: PositionClassification
    var dependents: [Int]  // indices of downstream structural nodes
}

struct DependencyDAG {
    let nodes: [DependencyNode]
    let topologicalOrder: [Int]
    let leafPositions: [ClosedRange<Int>]

    static func build(
        from sequence: ChoiceSequence,
        tree: ChoiceTree,
        bindIndex: BindSpanIndex
    ) -> DependencyDAG
}
```

**Implementation:** Single walk of the ChoiceTree alongside the
ChoiceSequence. For each `.bind` node, mark inner range as
`.structural(.bindInner)` and add edges to structural nodes within the
bound subtree. For each `.branch` node, mark as
`.structural(.branchSelector)` and add edges to structural nodes within
the selected subtree. Everything else is `.leaf`. Topological sort via
Kahn's algorithm. O(n) walk + O(m) sort where m = structural node count.

**Depends on:** `BindSpanIndex`, `ChoiceTree`, `ChoiceSequence`.

**Tests:** Unit tests verifying DAG construction for known generator
structures: single bind, nested binds, branch inside bind, independent
subtrees, getSize-bind (should not produce structural nodes).

**Estimated size:** ~200 lines.

### 0b. Structural constancy classification

Extend `DependencyDAG.build` (or add a parallel computation) to classify
each bind node as structurally constant or structurally dependent.

**Implementation:** For each bind region in `BindSpanIndex`, check
`ChoiceTree.containsBind` and `ChoiceTree.containsPicks` on the bound
subtree, and consult `RangeDependencyDetector` for range variability. A
bind is structurally constant if its bound subtree's shape (width,
nesting) does not depend on the inner value. Store classification on
`DependencyNode`.

**Depends on:** `RangeDependencyDetector`, `ChoiceTree` subtree inspection.

**Tests:** Verify classification for `Gen.int(...).flatMap { _ in Gen.string(length: 5) }` (constant) vs `Gen.int(...).flatMap { n in Gen.array(length: n, ...) }` (dependent).

**Estimated size:** ~50 lines added to DependencyDAG.

### 0c. Skeleton comparison

New struct or method for comparing two ChoiceTrees / ChoiceSequences by
width and bindDepthSum (the phase boundary guard).

```swift
struct SkeletonFingerprint: Equatable {
    let width: Int
    let bindDepthSum: Int

    static func from(_ tree: ChoiceTree, bindIndex: BindSpanIndex) -> SkeletonFingerprint
}
```

**Implementation:** `width` = `tree.flattenedEntryCount`. `bindDepthSum` =
sum of `bindIndex.bindDepth(at:)` across all positions. Both are O(n).

**Depends on:** `ChoiceTree.flattenedEntryCount`, `BindSpanIndex.bindDepth(at:)`.

**Tests:** Verify equality/inequality for known skeleton pairs.

**Estimated size:** ~30 lines.

---

## Milestone 1: Phase 0 -- Structural Independence Isolation

New file: `Sources/ExhaustCore/Interpreters/Reduction/StructuralIsolation.swift`

**Implementation:**

1. Build the DependencyDAG (Milestone 0a).
2. Compute the connected set: forward BFS/DFS from all structural roots
   (bind-inners and branch selectors) through dependency edges. O(n + e).
3. The independent set = all positions NOT in the connected set.
4. For each independent position, set its value to domain minimum in the
   ChoiceSequence.
5. Defensive verification: materialize and test the property. If the
   property passes, return the original unpruned trace. If it fails, return
   the pruned trace.

**Integration:** Called once at the start of `ReductionScheduler.run`,
before the V-cycle begins. The BonsaiReducer's existing entry point is
unchanged -- Phase 0 is prepended.

**Instrumentation:** Log the number of independent positions found and
whether verification passed. This data informs whether Phase 0 is earning
its keep for real-world generators.

**Tests:**
- Generator with independent subtrees: `#gen(.int(in: 0...10), .string(length: 5))` where property only inspects the int. Verify the string subtree is zeroed.
- Monolithic generator: `#gen(.int(in: 0...100).bind { n in ... })`. Verify Phase 0 makes no changes.
- Verification failure: synthetic property that hashes the entire value. Verify fallback to unpruned trace.

**Estimated size:** ~100 lines.

**Can ship independently:** Yes. Prepend Phase 0 to the existing
BonsaiReducer. No change to the V-cycle.

---

## Milestone 2: ProductSpaceEncoder

New file: `Sources/ExhaustCore/Interpreters/Reduction/Encoders/ProductSpaceEncoder.swift`

**Implementation:**

Two modes based on k (number of outer bind-inners from `BindSpanIndex`):

**k <= 3: BatchEncoder.** Enumerate the dependent product. For each
bind-inner, compute a binary search ladder (midpoints between current
value and domain minimum, maxSteps = 6). For independent bind-inners,
the product is Cartesian. For nested binds (DAG has edges between them),
compute candidate sets in topological order -- each downstream axis's
candidates are computed per upstream candidate value via `skeletonFor`.
Evaluate all candidates via REPLAY. Accept the shortlex-minimal one that
preserves failure. If no Tier 1 candidate passes, escalate: sort failures
by largest fibre first, escalate top 5 to Tier 2 (PRNG re-generation).

**k > 3: AdaptiveEncoder.** Halve all coordinates simultaneously (one
evaluation). If accepted, recurse. If rejected, delta-debug which subset
can be halved. O(k * log(range) * log(k)).

**Decoder:** `.guided(fallbackTree: currentTree)` for Tier 1.
`.guided(fallbackTree: nil)` for Tier 2 (forces PRNG).

**Depends on:** `DependencyDAG` (for topological order and nested bind
detection), `BindSpanIndex` (for bind-inner positions and ranges),
`ReductionMaterializer` (for materialization), existing `BinarySearchStepper`
(for computing search ladders).

**Tests:**
- Single bind (k=1): verify equivalent to current `BindRootSearchEncoder`.
- Two independent binds (k=2): verify joint search finds combinations that sequential search misses.
- Two nested binds (k=2, dependent): verify candidate sets respect domain dependencies.
- k=4: verify adaptive strategy triggers.
- Budget: verify worst-case probe count for k=3, maxSteps=6.

**Estimated size:** ~400 lines.

**Can ship independently:** Yes. Add as a new encoder alongside
`BindRootSearchEncoder`. Test via A/B comparison on the existing challenge
suite.

---

## Milestone 3: New Scheduler (PrincipledScheduler)

New file: `Sources/ExhaustCore/Interpreters/Reduction/PrincipledScheduler.swift`

This is the core architectural change. The new scheduler replaces the
V-cycle's five interleaved legs with the three-phase pipeline.

**Structure:**

```
run() {
    Phase 0: structuralIsolation() // Milestone 1
    REPEAT {
        Phase 1: structuralMinimization()
        Phase 2: valueMinimization()
    } UNTIL neither phase made progress
    Bounded speculation (RelaxRoundEncoder)
}
```

### Phase 1: structuralMinimization()

Inner loop with restart policy:

```
REPEAT {
    1a: branchSimplification()
        // PromoteBranchesEncoder, PivotBranchesEncoder
        // On success: recompute DAG, restart from 1a

    1b: structuralDeletion()
        // DeleteContainerSpansEncoder, DeleteSequenceElementsEncoder,
        // DeleteSequenceBoundariesEncoder, DeleteFreeStandingValuesEncoder,
        // DeleteAlignedWindowsEncoder, SpeculativeDeleteEncoder
        // Process in topological order from DAG
        // On success: recompute DAG, restart from 1b

    1c: jointBindInnerReduction()
        // ProductSpaceEncoder (Milestone 2)
        // ZeroValueEncoder, BinarySearchToZeroEncoder on structural targets
        // On success: recompute DAG, restart from 1a

} UNTIL full 1a->1b->1c pass makes no progress
```

**Decoder selection:**
- 1a: guided, relaxed strictness, `materializePicks: true`
- 1b: guided, relaxed strictness
- 1c: guided (Tier 1), PRNG fallback (Tier 2) via ProductSpaceEncoder's
  internal escalation

**Target set computation:** Use `DependencyDAG.leafPositions` for Phase 2
targets, structural node positions for Phase 1 targets. Replace the
current `SpanCache` depth-filtering with DAG-based classification.

### Phase 2: valueMinimization()

Flat pass over all leaf positions (from `DependencyDAG.leafPositions`),
with structural proximity ordering (leaves in recently-domain-shifted
bound subtrees first).

Encoders: `ZeroValueEncoder`, `BinarySearchToZeroEncoder`,
`BinarySearchToTargetEncoder`, `ReduceFloatEncoder`,
`TandemReductionEncoder`, `CrossStageRedistributeEncoder`.

Phase boundary guard for bind-inner values: compare
`SkeletonFingerprint` (width + bindDepthSum) before and after. If
unchanged, accept as a value shrink. If changed, reject. Use the
structural constancy classification from Milestone 0b to skip the
`skeletonFor` check for constant binds.

**Decoder selection:**
- Exact for generators without binds.
- Guided (Tier 1) for leaves inside bind-bound subtrees.
- After a bind-inner shrink that passes the boundary guard, the fallback
  tree reflects the old structure. Guided replay clamps to new domains.

### Integration

The new scheduler lives alongside `ReductionScheduler` as
`PrincipledScheduler`. Both are called from `BonsaiReducer.swift` based
on a configuration flag. This allows A/B testing.

**Depends on:** All of Milestones 0-2.

**Budget model:** Reuse `CycleBudget` with adjusted weights. Phase 1 gets
the majority (branch 5%, deletion 30%, product space 25%). Phase 2 gets
30%. Speculation gets 10%. Unused budget forwards between sub-phases
within a phase, and between phases within a cycle.

**Move-to-front ordering:** Reuse per-encoder cost estimation and
move-to-front promotion from `ReductionScheduler+EncoderSlots`. The slot
system maps directly -- encoders are grouped by sub-phase instead of by
leg.

**Stall detection:** Same mechanism as the current scheduler. Per-cycle
stallBudget, reset on shortlex improvement.

**Estimated size:** ~500 lines (scheduler logic, reusing existing encoder
infrastructure and `ReductionState` methods).

---

## Milestone 4: Validation and Cutover

### 4a. Test suite parity

Run the full existing test suite against `PrincipledScheduler`:

- All `ShrinkingChallenge` tests
- All `ScalingVariants` tests (constant, linear, logarithmic)
- All `ContractSpec` reduction tests
- Regression seeds

**Acceptance criteria:** Every test that passes with `ReductionScheduler`
also passes with `PrincipledScheduler`. Reduction quality (final
shortlex) must be equal or better. Probe count may differ.

### 4b. A/B comparison on reduction quality

For each test, compare:
- Final shortlex (should be <=)
- Total property evaluations (informational)
- Per-phase probe counts (informational)
- Cases where the cyclic variant finds improvements the strict variant
  does not (informs whether the cycle is earning its keep)

### 4c. Instrumentation

Add logging for:
- Phase 0: independent positions found, verification result
- Phase 1: sub-phase transitions, DAG recomputation count, product space
  candidate count and Tier 1 vs Tier 2 acceptance
- Phase 2: bind-inner shrinks that pass/fail the boundary guard,
  domain-shift events
- Tier escalation: per-bind Tier 1 stall -> Tier 2 escalation events
  (this data would have informed Tier 1.5 if we had built it)

### 4d. Cutover

When 4a-4c pass, make `PrincipledScheduler` the default behind
`.useBonsaiReducer`. Rename if desired. The old `ReductionScheduler`
remains available behind a configuration flag for regression comparison.

---

## Milestone 5: Retire BindRootSearchEncoder and BindAwareRedistributeEncoder

Once `ProductSpaceEncoder` is validated, remove the two subsumed encoders
and their associated code in `ReductionState` (encoder slot entries,
ordering logic). Update `ReductionScheduler+EncoderSlots.swift`.

This is a cleanup milestone -- it removes dead code after the new
scheduler is the default.

---

## Dependency Graph

```
0a (DependencyDAG) ──────────┬──── 1 (Phase 0)
                              │
0b (structural constancy) ───┤
                              │
0c (SkeletonFingerprint) ────┼──── 3 (PrincipledScheduler)
                              │
                    2 (ProductSpaceEncoder)
                              │
                              └──── 4 (Validation) ──── 5 (Cleanup)
```

Milestones 0a-0c are independent of each other and can be built in
parallel. Milestone 1 depends on 0a. Milestone 2 depends on 0a.
Milestone 3 depends on all of 0-2. Milestone 4 depends on 3.
Milestone 5 depends on 4.

---

## Risk Assessment

**Low risk:**
- Milestone 0 (infrastructure types, no behaviour change)
- Milestone 1 (Phase 0 is additive, fallback to unpruned trace on failure)
- Milestone 5 (cleanup, no new behaviour)

**Medium risk:**
- Milestone 2 (ProductSpaceEncoder). The batch enumeration for k <= 3 is
  straightforward. The adaptive strategy for k > 3 and the dependent
  product enumeration for nested binds have combinatorial complexity that
  needs careful testing. The budget model (maxSteps tuning, Tier 2
  escalation count) may need empirical adjustment.

**Higher risk:**
- Milestone 3 (PrincipledScheduler). This is the largest change and
  touches the most integration surfaces. The restart policy
  (1a/1b/1c -> restart targets), the phase boundary guard interaction
  with Phase 2's domain shifts, and the budget allocation across
  sub-phases all need careful testing. The mitigation is that the old
  scheduler remains available for comparison, and the new scheduler
  reuses existing encoder code rather than rewriting it.

---

## What is NOT in this plan

- **Tier 1.5 (targeted perturbation).** Removed from the architecture.
  The two-tier escalation (Tier 1 -> Tier 2) matches the current
  `BindRootSearchEncoder`'s behaviour. Instrumentation in Milestone 4c
  logs Tier 2 escalation events, providing data to revisit if needed.

- **True dynamic backward slicing.** Would require property instrumentation
  or observational learning. Phase 0's structural independence analysis is
  the feasible approximation.

- **bindDepthSum as a shortlex tiebreaker.** The skeleton size order uses
  (width, bindDepthSum, domainSum) for Phase 1's search heuristic, but
  the acceptance gate is shortlex on the full ChoiceSequence. Incorporating
  bindDepthSum into the shortlex comparison itself would require changes to
  `ChoiceSequence.shortLexPrecedes` and is not proposed here.

- **Human-order post-processing changes.** The existing post-processing
  step is orthogonal to the scheduler architecture and is retained as-is.
