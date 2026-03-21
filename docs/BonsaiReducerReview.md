# Bonsai Reducer Code Review

A structured analysis of the Bonsai reducer: Exhaust's alternating-minimisation shrinking engine operating over a fibred trace space. Covers ~4000 lines across `BonsaiScheduler`, `ReductionState`, `ReductionState+Bonsai`, `ReductionMaterializer`, `ChoiceDependencyGraph`, `StructuralIsolator`, `MutationPool`, `SequenceEncoder`, `DominanceLattice`, and 15+ encoder implementations.

## 1. Correctness Concerns

### 1.1 Signed bind-inner values in product-space encoders

**Severity: Medium (low probability, incorrect reduction path when triggered)**

`extractAxes` (ProductSpaceEncoder.swift:457) filters by `currentBitPattern > targetBitPattern` in UInt64 space:

```swift
guard currentBitPattern != targetBitPattern, currentBitPattern > targetBitPattern else {
    continue
}
```

For a signed integer with value -1, `currentBitPattern` is `0xFFFFFFFFFFFFFFFF` (two's complement). The `targetBitPattern` for `semanticSimplest` is 0 (the bit pattern of signed zero). The unsigned comparison `0xFFFFFFFFFFFFFFFF > 0` passes, so the axis is included.

`BinarySearchLadder.compute` (ProductSpaceEncoder.swift:22-44) then computes halving midpoints in unsigned space:

```swift
let midpoint = target + (value - target) / 2
// target=0, value=0xFFFFFFFFFFFFFFFF → midpoint = 0x7FFFFFFFFFFFFFFF
```

The midpoint `0x7FFFFFFFFFFFFFFF` is `Int64.max` (9223372036854775807). The ladder produces `[0xFFFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF, 0x3FFFFFFFFFFFFFFF, ...]` — huge positive numbers when the original was -1. These candidates are semantically meaningless as signed reduction steps.

In contrast, `BinarySearchToSemanticSimplestEncoder` handles this correctly with a dedicated cross-zero probe phase (BinarySearchToSemanticSimplestEncoder.swift:210-235) that walks down in shortlex key space for signed integers, correctly traversing 0, -1, 1, -2, 2, and so on.

**Practical impact:** Bind-inner values are almost always array lengths or enumeration discriminants (non-negative), making this scenario rare. When it does occur, the product-space candidates would be rejected by the decoder (property passes at `Int64.max`), wasting budget. The fallback tier 2 salted PRNG retries provide probabilistic coverage. No incorrect shrink results are produced — only suboptimal ones.

**Remediation:** Add tag-awareness to `BinarySearchLadder.compute` or use shortlex keys instead of raw bit patterns for signed types.

---

### 1.2 Relax-round cache leakage on rollback

**Severity: Medium-Low (performance degradation, not incorrect results)**

`runRelaxRound` (ReductionState.swift:518-615) manually checkpoints seven fields (lines 520-526):

```swift
let checkpointSequence = sequence
let checkpointTree = tree
let checkpointOutput = output
let checkpointFallbackTree = fallbackTree
let checkpointBindIndex = bindIndex
let checkpointBestSequence = bestSequence
let checkpointBestOutput = bestOutput
```

On rollback (lines 605-612), the same seven fields are restored. Four fields are omitted:

| Field | Omitted from checkpoint | Impact on rollback |
|-------|------------------------|-------------------|
| `branchTreeDirty` | Yes | Benign — stays `true` after `accept()`, triggers re-materialization next cycle |
| `spanCache` | Yes | Benign — invalidated at the start of `runFibreDescent` (line 615) and `runBaseDescent` rebuilds DAG |
| `lattice` | Yes | Benign — invalidated at the start of `runFibreDescent` (line 616) |
| `convergenceCache` | Yes | **Concerning** — entries from the discarded speculative path persist into subsequent cycles |

Contrast with `makeSnapshot`/`restoreSnapshot` (lines 436-465), which captures all 11 mutable fields including `convergenceCache`.

**The convergenceCache concern:** After a failed relax-round, stale convergence entries (warm-start bounds) from the speculative path remain. On the next cycle, binary search encoders receive these bounds. The validation probe phase catches invalid warm starts (the encoder probes `floor - 1` before committing), causing a restart from scratch. This wastes budget but does not produce incorrect results.

**Remediation:** Either capture `convergenceCache` in the checkpoint and restore it on rollback, or call `convergenceCache.invalidateAll()` on rollback. Given that `spanCache`, `lattice`, and `branchTreeDirty` are harmless, replacing the manual checkpoint with `makeSnapshot`/`restoreSnapshot` would be the cleanest fix and would prevent future field-addition bugs.

---

### 1.3 `accept` unconditionally overwrites `bestSequence` for bind generators

**Severity: Low (deliberate design trade-off, documented here for completeness)**

Lines 213-218 of ReductionState.swift:

```swift
if hasBind {
    bestSequence = sequence
    bestOutput = output
} else if sequence.shortLexPrecedes(bestSequence) {
    bestSequence = sequence
    bestOutput = output
}
```

When `hasBind` is true, every acceptance overwrites `bestSequence` regardless of shortlex ordering. If base descent shortens the sequence and a subsequent fibre descent acceptance produces a longer sequence (possible when bind-inner value changes expand bound regions), the shorter sequence from base descent is lost.

**Why it works this way:** This is a deliberate design choice, not an oversight. After structural changes, the previous `bestSequence` belongs to a different base point (different tree shape) and may not be materializable under the new structure. Keeping a stale `bestSequence` from a prior base point would trade within-cycle regression risk for stale-baseline bugs — a worse class of error. The code opts to always track the current state and relies on the scheduler's cycle-level stall detection (BonsaiScheduler.swift:120-124) to catch net regressions across cycles.

**Practical impact:** Within-cycle regression requires fibre descent to accept a candidate that increases sequence length — which the fingerprint guard should prevent for most cases (it detects structural changes and rolls back). The scenario where this matters is a structurally-constant bind whose inner value change causes bound content to grow, bypassing the fingerprint guard because `isStructurallyConstant` is true. No measured regression in the challenge suite has been attributed to this behavior.

---

### 1.4 `sizeOverride` can leak across scope boundaries in ReductionMaterializer

**Severity: Low (requires malformed generator to trigger)**

`handleResize` (ReductionMaterializer.swift:861) sets `context.sizeOverride = newSize` before recursing into the inner generator. The override is consumed by the first `.getSize` operation encountered (line 243-244):

```swift
let size = context.sizeOverride ?? context.size
context.sizeOverride = nil
```

If the inner generator of `.resize` does not contain a `.getSize` operation, the override persists into the continuation (a different resize scope). The continuation's first `.getSize` would incorrectly receive the stale override.

**Practical impact:** In well-formed generators, `.resize(newSize, gen)` always wraps a generator that reads `.getSize` — the resize node is only emitted by `Gen.resize(to:)`, which wraps a generator that subsequently calls `getSize`. The invariant is not enforced by the type system, but no existing generator violates it.


## 2. Soundness and Rigor Gaps

### 2.1 `StructuralFingerprint` is a weak hash, not a structural identity

**Severity: Medium (false negatives in boundary enforcement)**

`StructuralFingerprint` (ChoiceDependencyGraph.swift:398-423) captures only two fields:

```swift
public let width: Int
public let bindDepthSum: Int
```

Two structurally different trees can produce equal fingerprints if values migrate between bind depths with compensating sums. For example: one value moves from depth 2 to depth 0 while another moves from depth 0 to depth 2. Both trees have the same `width` and `bindDepthSum`, but different structures.

The fingerprint guard in `runAdaptive` (ReductionState.swift:337-351) relies on fingerprint inequality to detect structural crossings during fibre descent. A false-negative (equal fingerprints for different structures) means a structural change passes undetected. The acceptance is committed as a fibre-only change when it actually changed the base point, violating the cartesian-vertical factorisation.

**Existing tests:** ChoiceDependencyGraphTests.swift tests fingerprint equality and differentiation (lines 254-311) but only tests cases where `width` or `bindDepthSum` differ. No tests construct the compensating-depth-sum scenario.

**Remediation options:**
- Add `bindDepthProfile` (sorted array of per-value depths or histogram) instead of just the sum. This eliminates the compensating-sum collision.
- Alternatively, hash the full depth sequence with a rolling hash for O(n) computation with strong collision resistance.

---

### 2.2 The categorical framing is invoked in optimisation decisions but not formally proved

**Severity: Informational (documentation gap, not a code bug)**

The scheduler documentation (BonsaiScheduler.swift:1-18) describes the reduction as alternating minimisation over a fibred trace space. Several optimisation decisions rely on categorical properties:

- **Uniqueness of cartesian lifts:** The regime probe in Phase 1c (ReductionState+Bonsai.swift:377-477) avoids PRNG retries in the elimination regime on the assumption that the trace space forms a simple fibration with unique cartesian lifts. If lifts are not unique, valid reductions may exist in alternative lifts that are never explored.

- **Factorisation boundary enforcement:** The fingerprint guard (Section 2.1) enforces the cartesian-vertical factorisation. The correctness of the overall reduction depends on the factorisation being exhaustive — every reduction decomposes into a base step followed by a fibre step. This is asserted but not established formally.

- **Relax-round as non-monotone endomorphism:** The relax-round (ReductionState.swift:513-517) is described as breaking the fibred factorisation at the step level. The claim that it "recovers at the pipeline level" depends on the shortlex comparison at line 591 being a valid measure of global progress. For bind generators (where `bestSequence` tracks the working state unconditionally, per Section 1.3), this measure is weakened.

The fibred minimisation companion document does specify the categorical ingredients: morphisms are structural inclusions in a poset (Section 4.1: "that category is a poset under structural inclusion: T' ≤ T when T' can be obtained from T by deleting spans"), and the projection is ChoiceSequence-to-ChoiceTree structural extraction. These are not absent — they are specified in the companion doc, not in the code comments. The core gap is that the factorisation has been argued but not formally proved. The distinction between "categorically motivated" and "categorically proven" is worth making explicit in the code-level documentation.

---

### 2.3 `computeDependentDomains` assumes positional stability of region indices

**Severity: Low (acknowledged in code, mitigated by materializer validation)**

`computeDependentDomains` (ReductionState+Bonsai.swift:885-982) replays the generator with each upstream ladder value and reads the downstream axis's domain from the fresh `BindSpanIndex` by region index:

```swift
// This assumes region indices are positionally stable across upstream value changes.
// If the upstream's continuation conditionally constructs generators with different
// bind topologies (for example, 2 nested binds for n=10 vs 0 for n=3), region
// indices can shift and we may read the wrong domain.
```
(Lines 955-958)

The mitigation ("materializer validates at evaluation time") catches invalid tuples — candidates with out-of-range values are rejected by the decoder. But valid tuples in domains that are never discovered are missed. For generators where upstream values change the bind topology, the optimal tuple may live in a domain that `computeDependentDomains` never sees.

**Practical impact:** Requires three or more nested data-dependent (non-`getSize`) binds where each inner value determines the valid range of the next. Tier 2 salted PRNG retries provide probabilistic coverage of tuples that tier 1 misses. The code comments (lines 884-898) provide a thorough analysis of why the approximation is acceptable.


## 3. Performance Concerns

### 3.1 `StructuralFingerprint.from` re-flattens the tree every call

**Severity: Medium (O(n) allocation on every fingerprint computation, in a hot loop)**

`StructuralFingerprint.from` (ChoiceDependencyGraph.swift:411) calls `ChoiceSequence(tree)` to flatten the tree:

```swift
let sequence = ChoiceSequence(tree)
```

This allocates an O(n) sequence on every call. In fibre descent with the fingerprint guard enabled, fingerprint computation happens per-acceptance in per-leaf-range, per-slot loops (`runAdaptive` → `accept` → fingerprint check at ReductionState.swift:344). For large sequences (hundreds of entries), the repeated allocation and traversal is significant.

**Remediation:** The fingerprint only needs to iterate value/reduced entries and sum their bind depths. `tree.flattenedEntryCount` is already computed without allocation (line 410). The depth sum could be computed by walking the tree directly (matching the flatten order) or by reusing the existing `ChoiceSequence` that `ReductionState` already holds. After `accept` rebuilds `bindIndex`, the `sequence` field already contains the up-to-date flattened form.

---

### 3.2 Broad `@inline(__always)` in ReductionMaterializer

**Severity: Low (profile-driven, but scope may be wider than necessary)**

ReductionMaterializer.swift applies `@inline(__always)` to 10 methods, including the large handlers:

| Method | Lines | Annotation Location |
|--------|-------|-------------------|
| `handlePick` | ~155 lines | Line 478 |
| `handleSequence` | ~142 lines | Line 637 |
| `handleZip` | ~57 lines | Line 783 |
| `handleResize` | ~27 lines | Line 844 |
| `handleTransform` | ~100 lines | Line 875 |
| `handleChooseBits` | ~84 lines | Line 393 |
| `runContinuation` | ~30 lines | Line 319 |
| `handleContramap` | ~18 lines | Line 350 |
| `handlePrune` | ~23 lines | Line 369 |
| `decomposeNonGroupFallback` | ~15 lines | Line 145 |

**Historical context:** These annotations were added in commit `60229c9` ("Perf work on ReductionMaterializer", March 2026), part of a broader profiling-driven optimization pass that also included `InlineArray<8, Int>` stack allocation for cursor scope limits and wrapping arithmetic operators (`&+=`, `&-=`). The annotations are not speculative — they were added alongside measured improvements.

**Concern:** Force-inlining all handlers into `generateRecursive` (which is itself recursive) bloats code size proportionally to the recursion depth. For `handlePick` (~155 lines) and `handleSequence` (~142 lines), the code size cost may exceed the call overhead savings. However, given the profiling provenance, the current annotations should not be removed without re-profiling.

**Remediation:** If code size or instruction cache pressure is ever measured as a concern, selectively remove `@inline(__always)` from `handlePick` and `handleSequence` while retaining it on the smaller handlers. Profile before and after.

---

### 3.3 `ConvergenceCache.invalidate(in:)` iterates all keys

**Severity: Low (small cache sizes in practice)**

`ConvergenceCache.invalidate(in:)` (ReductionState.swift:55-59):

```swift
mutating func invalidate(in range: ClosedRange<Int>) {
    for index in entries.keys where range.contains(index) {
        entries.removeValue(forKey: index)
    }
}
```

This is O(entries.count) per call. Sibling invalidation (`invalidateConvergenceCacheSiblings` at ReductionState.swift:227-238) calls this per-region, producing O(entries × regions) total work.

**Practical impact:** The convergence cache typically contains one entry per value coordinate that converged. For most generators, this is tens of entries, not thousands. The linear scan is not a bottleneck at current scale.

**Remediation (if scale increases):** A sorted-key structure or interval tree would reduce per-invalidation cost to O(log n + k) where k is the number of removed entries.

---

### 3.4 `buildBindInnerValueSpans` allocates an O(n) boolean array

**Severity: Low (single allocation, small constant factor)**

`buildBindInnerValueSpans` (ReductionState+Bonsai.swift:589):

```swift
var inBindInner = [Bool](repeating: false, count: sequence.count)
for region in bindSpanIndex.regions {
    for i in region.innerRange {
        inBindInner[i] = true
    }
}
return allValueSpans.filter { inBindInner[$0.range.lowerBound] }
```

Allocates a full-width boolean array for a simple membership test.

**Remediation:** Replace with inline range checks against `bindSpanIndex.regions`, or use a `Set<Int>` of inner positions. Given that the method is called at most once per base descent pass, the impact is negligible.

---

### 3.5 Mutation pool disjointness check is O(s_a * s_b) per pair

**Severity: Low (capped at 190 pairs with small span counts)**

`MutationPool.areDisjoint` (MutationPool.swift:129-138):

```swift
private static func areDisjoint(_ a: [ChoiceSpan], _ b: [ChoiceSpan]) -> Bool {
    for spanA in a {
        for spanB in b {
            if spanA.range.asRange.overlaps(spanB.range.asRange) {
                return false
            }
        }
    }
    return true
}
```

This is O(s_a × s_b) per pair, called up to 190 times (C(20, 2) from `individualLimit = 20`). Total work is O(190 × s_a × s_b).

**Practical impact:** Span counts per entry are typically small (1-5 spans per deletion candidate). With typical sizes, this is ~190 × 25 = 4750 range comparisons — negligible.

**Remediation (if span counts grow):** Sort spans by start position and use a sweep-line intersection algorithm for O((s_a + s_b) log(s_a + s_b)) per pair.


## 4. Architectural Concerns

### 4.1 `ReductionState` is a mutable bag with no encapsulation

**Severity: Medium (maintenance hazard)**

`ReductionState` (ReductionState.swift:84-183) is a `final class` with 14+ mutable `var` fields, all at default (internal) access:

```swift
var sequence: ChoiceSequence
var tree: ChoiceTree
var output: Output
var fallbackTree: ChoiceTree?
var bindIndex: BindSpanIndex?
var bestSequence: ChoiceSequence
var bestOutput: Output
var spanCache: SpanCache
var lattice: DominanceLattice
var rejectCache = Set<UInt64>(minimumCapacity: 512)
var convergenceCache = ConvergenceCache()
var convergenceInstrumentation: ConvergenceInstrumentation?
var currentCycle = 0
var branchTreeDirty = true
```

Plus 15 encoder instances and 3 ordering arrays.

The `Snapshot` struct (lines 119-131) must manually mirror every field that `accept` can modify. Adding a field to `ReductionState` without adding it to `Snapshot` is a silent bug with no compiler warning. The `runRelaxRound` method uses a separate manual checkpoint (lines 520-526) that doesn't even match `Snapshot`'s field set — it omits `branchTreeDirty`, `spanCache`, `lattice`, and `convergenceCache` (see Section 1.2).

This dual-checkpoint pattern is a maintenance hazard. A future contributor adding a new cache field must update three places: the field declaration, the `Snapshot` struct, and the `runRelaxRound` checkpoint.

**Remediation:** Unify checkpointing by making `runRelaxRound` use `makeSnapshot`/`restoreSnapshot`. Consider grouping the mutable reduction state into a nested struct (for example, `MutableState`) so that `Snapshot` can be generated from it systematically.

---

### 4.2 Budget constants are magic numbers with no derivation

**Severity: Low (works well in practice, but rationale is undocumented)**

BonsaiScheduler.swift lines 22-29:

```swift
static let baseDescentBudget = 1950
static let fibreDescentBudget = 975
static let relaxRoundBudget = 325
```

The ratio is approximately 6:3:1 (or 2:1:0.33 of the base budget). These constants directly control the time allocation between structural and value reduction, which is the primary performance lever of the scheduler. Their values have no documented justification — no empirical derivation, no theoretical basis, no sensitivity analysis.

**Remediation:** Add a comment block explaining the rationale (for example, "Empirically tuned on the challenge suite; base descent is 2x fibre because structural changes unlock more value reduction than vice versa; relax-round is small because it's speculative"). Consider making these configurable via `BonsaiReducerConfiguration` for tuning.

---

### 4.3 Encoder ordering is split across three independent arrays

**Severity: Low (confusing but functional)**

ReductionState.swift lines 152-154:

```swift
var snipOrder: [ReductionScheduler.ValueEncoderSlot] = ...
var pruneOrder: [ReductionScheduler.DeletionEncoderSlot] = ...
var trainOrder: [ReductionScheduler.ValueEncoderSlot] = ...
```

`snipOrder` and `trainOrder` both contain `ValueEncoderSlot` elements and start identical (line 502: `trainOrder = snipOrder`). They diverge via independent `moveToFront` calls during the cycle. The naming does not clearly convey which phase each serves:

- `snipOrder` is used for leaf-range value minimization in fibre descent
- `trainOrder` is used for contravariant-sweep value minimization in fibre descent
- `pruneOrder` is used for structural deletion in base descent

The interaction between `snipOrder` and `trainOrder` is not documented — they share the same encoder pool but maintain independent move-to-front state.

**Remediation:** Add doc comments explaining the naming convention and why two independent value orderings are needed. Consider renaming to `leafValueOrder` and `boundValueOrder` for clarity.


## 5. Testing Gaps

### 5.1 No property tests for the reducer's own invariants

**Severity: Medium (these are the highest-value missing tests)**

There are no randomised meta-tests verifying:

- **Shortlex monotonicity across acceptances:** For non-bind generators, `bestSequence` should never regress. A property test could run the reducer on random generators and assert `bestSequence[i+1].shortLexPrecedes(bestSequence[i])` for each acceptance.
- **Property preservation after reduction:** The reduced output should still fail the property. A property test could verify `property(reducedOutput) == false` for random generators and properties.
- **Materialisation consistency:** `ReductionMaterializer.materialize(gen, prefix: sequence, mode: .exact)` should produce a result whose flattened sequence matches `sequence` for all values. A round-trip property test would catch scope management bugs.

These invariants are the foundation of reducer correctness. Unit tests cover specific scenarios, but property tests would provide broader coverage against regression.

---

### 5.2 The relax-round rollback path is untested in isolation

**Severity: Medium**

No tests verify that all state (including caches) is correctly restored after a failed relax-round. The relax-round is tested indirectly through `BonsaiSchedulerTests.terminatesWithinBudget` (line 210), but this test does not inspect post-rollback state.

A targeted test should:
1. Set up a state where redistribution succeeds but the full pipeline does not improve.
2. Verify that all state fields match the pre-relax checkpoint after rollback.
3. Specifically verify `convergenceCache` is not polluted (per Section 1.2).

---

### 5.3 Deep bind nesting (k > 3) is not covered by unit tests

**Severity: Medium**

The `ProductSpaceAdaptiveEncoder` (delta-debug for k > 3, ProductSpaceEncoder.swift:227-424) has no dedicated tests with four or more nested bind regions. Only `estimatedCost` is implicitly tested for k = 4 (via the guard at line 235). The delta-debug partitioning logic (`probeHalveAll`, `probeDeltaDebug`, subdivision) is not directly exercised by any test.

Across all reducer test files:
- `BonsaiReducerTests.swift`: Only depth 1 nesting
- `BonsaiSchedulerTests.swift`: Only depth 1 nesting
- `BindAwareReducerTests.swift`: Maximum depth 2 (`nestedBinds`)
- `ChoiceDependencyGraphTests.swift`: Maximum depth 2 (`nestedBinds`)

---

### 5.4 Convergence cache correctness across structural changes is not tested

**Severity: Low-Medium**

No tests verify that:
- Invalidated entries produce correct behavior on subsequent cycles (encoders restart without warm start).
- Sibling invalidation (`invalidateConvergenceCacheSiblings`) correctly identifies and removes stale entries.
- Entries surviving a structural change (outside the changed bind scope) remain valid.

---

### 5.5 Regime detector edge cases are not tested

**Severity: Low-Medium**

The three-regime probe (Section 7.1) has no dedicated unit tests. In particular:
- No test verifies that the elimination regime correctly skips PRNG retries when the simplest-values probe succeeds.
- No test verifies that the value-sensitive regime correctly proceeds with all retries.
- No test constructs a generator where the simplest-values probe is rejected (unknown regime) due to range violations after inner value zeroing.

The regime detector is exercised indirectly through end-to-end scheduler tests, but targeted tests would catch regressions in the regime classification logic.

---

### 5.6 StructuralFingerprint collision scenarios are not tested

**Severity: Low-Medium**

The existing fingerprint tests (ChoiceDependencyGraphTests.swift:254-311) verify basic equality and inequality based on `width` and `bindDepthSum`. No tests construct the compensating-depth-sum scenario described in Section 2.1, where two structurally different trees produce equal fingerprints.

A test should construct two generators with the same width and bindDepthSum but different per-position bind-depth distributions, and verify that the fingerprint guard detects (or fails to detect) the structural change.


## 6. Minor Issues

### 6.1 `StructuralIsolator.project` takes `tree` parameter but names it `_`

StructuralIsolator.swift:47:

```swift
static func project<Output>(
    gen: ReflectiveGenerator<Output>,
    sequence: ChoiceSequence,
    tree _: ChoiceTree,
    // ...
```

The `tree` parameter is accepted but unused. Either remove it from the signature or document why it is reserved for future use. The caller (`BonsaiScheduler.run`, line 60) passes `state.tree`, suggesting the parameter was once used or is planned for future use.

---

### 6.2 `buildDeletionScopes` always appends depth-0 scope

ReductionState+Bonsai.swift:1014:

```swift
// Depth-0 content outside all structural nodes.
scopes.append(DeletionScope(positionRange: nil, depth: 0))
```

This depth-0 scope uses depth-based filtering (`positionRange: nil`), which matches all depth-0 spans regardless of position. When the DAG's structural nodes already cover all depth-0 positions via position-ranged scopes (lines 994-1011), the depth-0 catch-all duplicates those targets. Deletion encoders will attempt to delete the same spans twice, wasting budget.

**Impact:** The duplicate attempts hit the reject cache on the second pass (same candidate sequence hash), so the wasted work is limited to cache lookup overhead. Not a correctness issue.

**Remediation:** Only append the depth-0 scope if there are leaf positions outside all structural node scope ranges (this information is already available in `dag.leafPositions`).

---

### 6.3 `DominanceLattice` naming is misleading

The implementation encodes categorical 2-cell dominance across encoder hom-sets (Sepulveda-Jimenez, Def 15.3, referenced in the fibred minimisation doc Section 2). The dominance edges capture a meaningful relationship: within each hom-set, a more-aggressive encoder's success makes a less-aggressive encoder's probes redundant because they can only find reductions the dominator already found. The two chains — deletion (`containerSpans`/`alignedWindows` ⇒ `randomRepair`) and value minimization (`zeroValue` ⇒ `binarySearchToSemanticSimplest` ⇒ `binarySearchToRangeMinimum`) — are correctly scoped per phase and invalidated at leg boundaries.

The issue is purely nominal: the name "lattice" implies an algebraic structure with meets and joins. This is a finite poset with at most two chains — no meets, no joins, not a lattice in the algebraic sense.

**Remediation:** Rename to `EncoderDominance` to reflect the 2-cell structure accurately without the algebraic overreach. The doc comment should retain the Sepulveda-Jimenez reference.

---

### 6.4 Reject cache has no collision handling

ReductionState.swift:102:

```swift
var rejectCache = Set<UInt64>(minimumCapacity: 512)
```

The cache uses Zobrist hashing (`ZobristHash.hash(of: candidate) &+ cacheSalt`) which produces 64-bit hashes. With 512+ entries, birthday-paradox collisions become non-negligible (probability exceeds 1% at ~600M entries, but false positives accumulate over many cycles). A false positive causes a valid candidate to be skipped.

**Impact:** This is an optimality concern, not a correctness concern. False positives reduce the search space, potentially missing a simpler counterexample. The per-decoder salt reduces cross-decoder false positives.

**Remediation:** If needed, switch to a Bloom filter with tunable false-positive rate, or use a larger hash (128-bit) to push the collision threshold far beyond practical cache sizes.


## 3.6 Iterator protocol overhead in debug builds

**Severity: Medium (debug-mode performance, where most users run tests)**

Swift's `for...in` loops, `.enumerated()`, `.filter {}`, `.map {}`, and Dictionary iteration create iterator protocol witnesses that are not optimized away in debug builds (`-Onone`). Since property-based testing libraries are primarily exercised through test targets compiled without optimization, iterator overhead in hot paths directly impacts shrinking wall-clock time.

**Audit scope:** All encoder files, `SpanCache`, `MutationPool`, `DominanceLattice`, and `SequenceEncoder`.

### Hot-path concerns (per-probe or per-acceptance)

**1. `ProductSpaceAdaptiveEncoder.restoreSavedEntries()` — Dictionary iteration per-probe**

ProductSpaceEncoder.swift:418-423:

```swift
private mutating func restoreSavedEntries() {
    for (coordIndex, saved) in savedEntries {
        sequence[coordinates[coordIndex].seqIdx] = saved
    }
    savedEntries.removeAll(keepingCapacity: true)
}
```

Called on every rejected probe (the common case). Dictionary iteration allocates an iterator struct and performs per-element hashing. With up to k coordinates (k > 3 for this encoder), the overhead is small per call but multiplies across many probes.

**Fix:** Replace `savedEntries: [Int: ChoiceSequenceValue]` with a flat array `savedEntries: [(coordIndex: Int, saved: ChoiceSequenceValue)]`. Iteration becomes a simple index loop, and `removeAll(keepingCapacity:)` works the same.

**2. `SpanCache` depth-filtered accessors — `.filter` creating intermediate arrays per-leg**

SpanCache.swift:70-120 — five accessors (`valueSpans`, `siblingGroups`, `floatSpans`, `deletionTargets` x2) each call `.filter {}` on the cached raw spans, creating a new intermediate array on every call:

```swift
return all.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
```

These are called per-leg, per-depth, and per-scope in the structural deletion and fibre descent loops. The filters are not themselves cached — only the raw (unfiltered) spans are cached.

**Fix:** Cache the filtered results by (category, depth) key, not just the raw spans. Alternatively, replace `.filter` with an index-based loop that appends to a pre-allocated buffer, avoiding the closure-based iterator path.

### Warm-path concerns (per-encode, called once per encoder invocation)

**3. `ProductSpaceBatchEncoder.encode()` — nested iterator loops in product-space build**

ProductSpaceEncoder.swift:133-218 — the product-space build uses multiple `for...in` array loops, `.enumerated()`, and `.map {}`:

```swift
for axisIndex in enumerationOrder {           // for...in array
    for existing in tuples {                   // for...in array
        for value in ladder.values {           // for...in array
```

And candidate identity checking:

```swift
for (position, value) in tuple.enumerated() { // EnumeratedSequence iterator
```

The product space can be up to 512 candidates (8^3 for k=3). Each level of nesting creates iterator protocol overhead in debug mode.

**Fix:** Replace with index-based loops: `for ai in 0 ..< enumerationOrder.count`, `for ei in 0 ..< tuples.count`, and so on. Replace `.enumerated()` with manual index tracking.

**4. `DeleteByBranchPivotEncoder.encode()` — chained functional transforms per pick site**

DeleteByBranchPivotEncoder.swift:43-46:

```swift
let alternatives = elements.enumerated()
    .filter { $0.offset != selectedIndex }
    .map { (index: $0.offset, complexity: ChoiceSequence.flatten($0.element, ...)) }
    .sorted { lhs, rhs in lhs.complexity.shortLexPrecedes(rhs.complexity) }
```

Creates four intermediate collections (EnumeratedSequence, filtered array, mapped array, sorted array) per pick site. With multiple pick sites, this compounds.

**Fix:** Single index-based pass into a pre-allocated array, then in-place sort:

```swift
var alternatives = [(index: Int, complexity: ChoiceSequence)]()
alternatives.reserveCapacity(elements.count)
for i in 0 ..< elements.count where i != selectedIndex {
    alternatives.append((index: i, complexity: ChoiceSequence.flatten(elements[i], ...)))
}
alternatives.sort { $0.complexity.shortLexPrecedes($1.complexity) }
```

### Cold-path (no action needed)

The following files use iterator-based patterns only in setup/initialization code that runs once per encoder invocation or once per cycle. The overhead is negligible:

- `AlignedDeletionCohortBuilder` — cohort construction (once per `start()`)
- `RedistributeByTandemReductionEncoder` — plan construction helpers (once per `start()`)
- `MutationPool` — `collect()` and `composePairs()` (once per cycle)
- `DeleteByBranchPromotionEncoder` — `encode()` (batch, once per invocation)
- `ReduceFloatEncoder` — `start()` and `prepare*` setup

### Files with exemplary index-based patterns

Several encoders already use fully index-based loops, demonstrating the preferred pattern:

- `BinarySearchToSemanticSimplestEncoder` — all `while i < count` loops
- `BinarySearchToRangeMinimumEncoder` — all `while i < count` loops
- `AdaptiveDeletionEncoder` — all `while spanIndex < sortedSpans.count` loops
- `RelaxRoundEncoder` — `for ci in 0 ..< candidates.count` range loops
- `RedistributeAcrossValueContainersEncoder` — `while i < sequence.count` in hot paths

---


## 7. Additional Observations

### 7.1 Regime detector (Phase 1c) is correctly implemented

**Status: Reviewed, no issues found**

The three-regime probe described in the fibred minimisation document (Section 4.2) is fully implemented in `ReductionState+Bonsai.swift:377-477`. The implementation runs between Tier 1 (guided replay) and Tier 2 (PRNG retries) in Phase 1c (joint bind-inner reduction):

1. **Elimination regime** (lines 414-433): Simplest-values probe materializes, fails the property, and shortlex-improves. The failure is structural, not value-sensitive. Action: accept directly, skip PRNG retries.
2. **Value-sensitive regime** (lines 435-439): Simplest-values probe materializes but the property passes. Specific values are needed. Action: proceed with all four PRNG retries.
3. **Unknown regime** (lines 440-443, 466-468): Simplest-values probe is rejected (a value falls outside the valid range in the new structure). Action: proceed conservatively with retries.

The implementation correctly guards the elimination regime with a shortlex check (line 414) to prevent accepting non-improving results. The cost is one materialization; break-even occurs at >25% elimination frequency.

A cocartesian direction scaffold exists (lines 444-465, computing `g!(semanticSimplest)` by materializing the new fibre's simplest value assignment), currently disabled pending instrumentation data on unknown-regime frequency.

---

### 7.2 StructuralIsolator is strictly single-probe

**Status: Reviewed, matches specification**

`StructuralIsolator.project` (StructuralIsolator.swift:44-169) is a single-probe operation with no subset fallback. It zeroes all structurally independent positions in one candidate and makes exactly one materialization attempt in `.exact` mode:

- If materialization fails (prefix exhausted or out-of-range value): returns `nil`.
- If the property passes after zeroing: returns `nil`.
- No subset exploration — the operation is binary.

This matches the fibred minimisation document's description ("zeros structurally-independent values in a single probe"). The single-probe behavior is categorically correct: it is a fibre retraction (projection onto the shortlex-minimal point agreeing on all structurally coupled coordinates), not a search. If the retraction doesn't preserve the failure, the structural independence assumption is violated for the specific value combination, and Phase 0 contributes nothing.

The absence of a subset fallback is a design choice, not a gap. Trying subsets would convert a O(1)-probe retraction into an O(2^k) search over independent position subsets, undermining the Phase 0 budget justification.

---

### 7.3 RelaxRoundEncoder redistribution is correctly magnitude-preserving

**Status: Reviewed, matches specification**

`RelaxRoundEncoder` (RelaxRoundEncoder.swift) implements zero-sum redistribution at the bit-pattern level. For each (donor, absorber) pair:

1. Computes `delta = |donorValue - reductionTarget|` — the full distance the donor must move.
2. Moves the donor to its reduction target.
3. Adjusts the absorber by exactly `delta` in the opposite direction.
4. Guards against unsigned overflow (`rhsBitPattern >= delta` for subtraction, `UInt64.max - delta >= rhsBitPattern` for addition).
5. Validates that the new absorber value stays in range if range-explicit.

The total bit-pattern magnitude is conserved within the pair. When the donor's reduction target is not zero (for example, range minimum for bounded values), the "delta" is relative to that target. This is consistent with the fibred minimisation document's description: "zeroes one value by redistributing its magnitude to another."


## 8. Proposed Fixes

Concrete code changes for each finding, ordered by priority (highest first). Each fix is scoped to the minimal change that addresses the finding without restructuring surrounding code.

---

### Fix 1.2 — Unify relax-round checkpointing with `makeSnapshot`/`restoreSnapshot`

**Priority: High (eliminates a class of future bugs, fixes convergenceCache leakage)**

Replace the manual seven-field checkpoint in `runRelaxRound` with the existing `Snapshot` mechanism. This ensures all mutable fields (including `convergenceCache`, `spanCache`, `lattice`, `branchTreeDirty`) are captured and restored atomically.

**File:** `ReductionState.swift`

Replace the checkpoint block (lines 519-526):

```swift
func runRelaxRound(remaining: inout Int) throws -> Bool {
    let checkpoint = makeSnapshot()
```

Replace the early rollback (lines 575-581):

```swift
guard redistributionAccepted else {
    restoreSnapshot(checkpoint)
    remaining -= explorationBudget.used
    return false
}
```

Replace the pipeline acceptance block (lines 590-614):

```swift
if sequence.shortLexPrecedes(checkpoint.sequence) {
    bestSequence = sequence
    bestOutput = output
    remaining = exploitRemaining
    if isInstrumented {
        ExhaustLog.debug(category: .reducer, event: "exploration_accepted", metadata: [
            "seq_len": "\(checkpoint.sequence.count)→\(sequence.count)",
            "base_descent": "\(baseProgress)",
            "fibre_descent": "\(fibreProgress)",
        ])
    }
    return true
}

restoreSnapshot(checkpoint)
remaining -= explorationBudget.used
return false
```

**Budget accounting:** `explorationBudget` is a local variable in `runRelaxRound` (line 532: `var explorationBudget = ReductionScheduler.LegBudget(hardCap: remaining)`), not a field on `ReductionState`. `restoreSnapshot` does not touch it, so `explorationBudget.used` remains correct after restore.

The `rejectCache` is intentionally not in `Snapshot` — stale entries from the speculative path are harmless because candidates derived from a different base sequence produce different hashes.

---

### Fix 2.1 — Strengthen `StructuralFingerprint` with a depth hash

**Priority: High (eliminates false-negative collisions in boundary enforcement)**

Replace the `bindDepthSum` scalar with a rolling hash over the per-position bind depth sequence. This distinguishes trees where values migrate between bind depths with compensating sums (for example, one value from depth 2→0 and another from depth 0→2).

**File:** `ChoiceDependencyGraph.swift`

```swift
public struct StructuralFingerprint: Equatable, Sendable {
    public let width: Int
    public let depthHash: UInt64

    /// Computes the skeleton fingerprint from a choice sequence and its bind span index.
    ///
    /// Uses a position-sensitive rolling hash over per-value bind depths
    /// so that depth migrations with equal sums produce distinct fingerprints.
    public static func from(
        _ sequence: ChoiceSequence,
        bindIndex: BindSpanIndex
    ) -> StructuralFingerprint {
        let width = sequence.count
        var hash: UInt64 = 14_695_981_039_346_656_037  // FNV offset basis
        for i in 0 ..< sequence.count {
            switch sequence[i] {
            case .value, .reduced:
                let depth = UInt64(bindIndex.bindDepth(at: i))
                // Hash position and depth separately to ensure full avalanche.
                // XOR-multiply chains mix each component independently, so
                // adjacent positions with swapped depths (for example, (i,d) vs (i+1,d-1))
                // produce maximally different hash states.
                hash = (hash ^ UInt64(i)) &* 1_099_511_628_211
                hash = (hash ^ depth) &* 6_364_136_223_846_793_005
            default:
                break
            }
        }
        return StructuralFingerprint(width: width, depthHash: hash)
    }
}
```

**Signature change:** The factory method now takes `ChoiceSequence` instead of `ChoiceTree`, eliminating the O(n) `ChoiceSequence(tree)` allocation (also fixes Section 3.1). All call sites already have the sequence available:

- `runFibreDescent` (ReductionState+Bonsai.swift:632): change `StructuralFingerprint.from(tree, bindIndex:)` to `StructuralFingerprint.from(sequence, bindIndex:)`.
- `runAdaptive` fingerprint guard (ReductionState.swift:344): change `StructuralFingerprint.from(tree, bindIndex:)` to `StructuralFingerprint.from(sequence, bindIndex:)`. The `sequence` field is already up-to-date at this point — `accept` just set it.

**Invariant verification:** After `accept`, `self.sequence` is always the canonical flattened form of `self.tree`. Both `decodeExact` and `decodeGuided` construct `result.sequence = ChoiceSequence(result.tree)` explicitly. The GuidedMaterializer re-derivation path (lines 199-211) also derives sequence from tree via `ChoiceSequence(tree)`. No path through `accept` causes sequence and tree to diverge. The signature change from `ChoiceTree` to `ChoiceSequence` therefore checks the same structural invariant without the allocation cost.

**Tests:** Add a collision test to `ChoiceDependencyGraphTests.swift`:

```swift
@Test func compensatingDepthSumProducesDifferentFingerprint() {
    // Two sequences with same width and same total depth sum
    // but different per-position depth distributions.
    // Sequence A: positions [0,1,2] at depths [2,0,1]  (sum=3)
    // Sequence B: positions [0,1,2] at depths [0,2,1]  (sum=3)
    // Old fingerprint: equal. New fingerprint: distinct.
    // ...
}
```

---

### Fix 1.1 — Convert signed values to shortlex key space before product-space search

**Priority: Medium (correctness gap, but rare trigger condition)**

The fix keeps `BinarySearchLadder` tag-agnostic — it just needs "current > target, halve the distance." The coordinate system is the caller's concern. The changes are in `extractAxes` and the call sites that build ladders.

**File:** `ProductSpaceEncoder.swift`

**Part 1:** Make `extractAxes` operate in shortlex key space for filtering and axis state:

```swift
func extractAxes(
    from sequence: ChoiceSequence,
    bindIndex: BindSpanIndex
) -> [AxisState] {
    var axes = [AxisState]()
    for (regionIndex, region) in bindIndex.regions.enumerated() {
        for index in region.innerRange where index < sequence.count {
            guard let value = sequence[index].value else { continue }
            let currentBitPattern = value.choice.bitPattern64
            let isWithinRecordedRange = value.isRangeExplicit && value.choice.fits(in: value.validRange)
            let targetBitPattern: UInt64 = if isWithinRecordedRange {
                value.choice.reductionTarget(in: value.validRange)
            } else {
                value.choice.semanticSimplest.bitPattern64
            }

            // Compare in shortlex key space so that signed values near zero
            // (for example, -1 with shortlex key 1) are correctly ordered relative to
            // the target (for example, 0 with shortlex key 0).
            let currentKey = value.choice.shortlexKey
            let targetValue = ChoiceValue(
                value.choice.tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: value.choice.tag
            )
            let targetKey = targetValue.shortlexKey
            guard currentKey != targetKey, currentKey > targetKey else {
                continue
            }

            axes.append(AxisState(
                regionIndex: regionIndex,
                seqIdx: index,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit,
                choiceTag: value.choice.tag,
                currentBitPattern: currentKey,    // shortlex key, not raw bit pattern
                targetBitPattern: targetKey        // shortlex key, not raw bit pattern
            ))
        }
    }
    return axes
}
```

**Part 2:** Convert ladder results back to bit patterns when building candidate sequences. `BinarySearchLadder.compute` remains unchanged — it operates on whatever coordinate system the caller provides. The callers convert the ladder's shortlex-key midpoints back to bit patterns when writing into the candidate sequence:

```swift
// In ProductSpaceBatchEncoder.encode, when building candidate entries:
let bitPattern = ChoiceValue.fromShortlexKey(value, tag: axis.choiceTag).bitPattern64
candidate[axis.seqIdx] = .value(.init(
    choice: ChoiceValue(axis.choiceTag.makeConvertible(bitPattern64: bitPattern), tag: axis.choiceTag),
    validRange: axis.validRange,
    isRangeExplicit: axis.isRangeExplicit
))
```

Similarly in `ProductSpaceAdaptiveEncoder.probeHalveAll` and `probeDeltaDebug`: convert `midpoint` from shortlex key space back to bit pattern before writing into the sequence.

**Why this is better than making BinarySearchLadder tag-aware:** The ladder is a small, focused utility that computes halving midpoints in an ordered space. Adding tag-awareness doubles its body with a parallel code path. Keeping the coordinate-system concern in the caller preserves the ladder's simplicity and makes the conversion explicit at each call site.

---

### Fix 3.6 — Eliminate iterator protocol overhead in hot and warm encoder paths

**Priority: Medium (directly impacts debug-mode shrinking performance)**

Four targeted changes, ordered by impact:

**3.6a — `ProductSpaceAdaptiveEncoder.restoreSavedEntries()` (hot, per-probe)**

Replace Dictionary with flat array:

```swift
// Replace:
private var savedEntries: [Int: ChoiceSequenceValue] = [:]

// With:
private var savedEntries: [(coordIndex: Int, saved: ChoiceSequenceValue)] = []

// restoreSavedEntries becomes:
private mutating func restoreSavedEntries() {
    for i in 0 ..< savedEntries.count {
        let entry = savedEntries[i]
        sequence[coordinates[entry.coordIndex].seqIdx] = entry.saved
    }
    savedEntries.removeAll(keepingCapacity: true)
}
```

Also update `probeHalveAll` and `probeDeltaDebug` to append tuples instead of dictionary keying. The `savedEntries.keys.sorted()` call (line 342) becomes `savedEntries.map(\.coordIndex).sorted()` or, better, maintain a separate `activeIndices` array.

**3.6b — `SpanCache` depth-filtered accessors (hot, per-leg per-depth)**

Add a per-depth cache layer:

```swift
private var cachedValueSpansByDepth: [Int: [ChoiceSpan]] = [:]

mutating func valueSpans(
    at depth: Int, from sequence: ChoiceSequence, bindIndex: BindSpanIndex?
) -> [ChoiceSpan] {
    if let cached = cachedValueSpansByDepth[depth] { return cached }
    let all = allValueSpans(from: sequence)
    var result = [ChoiceSpan]()
    if let bi = bindIndex {
        for i in 0 ..< all.count {
            if bi.bindDepth(at: all[i].range.lowerBound) == depth {
                result.append(all[i])
            }
        }
    } else {
        result = all
    }
    cachedValueSpansByDepth[depth] = result
    return result
}
```

Add `cachedValueSpansByDepth = [:]` to `invalidate()`. Repeat the pattern for `siblingGroups`, `floatSpans`, and `deletionTargets`.

**3.6c — `ProductSpaceBatchEncoder.encode()` product build (warm, per-encode)**

Replace `for...in` array loops and `.enumerated()` with index-based equivalents:

```swift
// Replace:
for axisIndex in enumerationOrder { ... }
// With:
for ai in 0 ..< enumerationOrder.count {
    let axisIndex = enumerationOrder[ai]
    ...
}

// Replace:
for (position, value) in tuple.enumerated() { ... }
// With:
for position in 0 ..< tuple.count {
    let value = tuple[position]
    ...
}
```

**3.6d — `DeleteByBranchPivotEncoder.encode()` chained transforms (warm, per-encode)**

Replace `.enumerated().filter().map().sorted()` chain with a single index-based pass (see Section 3.6 finding for the replacement code).

---

### ~~Fix 1.3~~ — No fix (deliberate design trade-off)

The unconditional `bestSequence` overwrite for bind generators is a deliberate choice to avoid stale-baseline bugs (see Section 1.3). Adding a `cycleBaseline` field would trade one class of bugs (within-cycle regression) for another (stale baseline from a prior tree shape that is no longer materializable). No measured regression in the challenge suite has been attributed to this behavior. The finding is documented for awareness but does not warrant a code change.

---

### Fix 1.4 — Clear `sizeOverride` after resize recursion

**Priority: Low (only affects malformed generators)**

**File:** `ReductionMaterializer.swift`

Add a defensive clear after the recursive call returns, ensuring the override cannot leak into the continuation:

```swift
// In handleResize, after the generateRecursive call:
context.sizeOverride = newSize
guard let result = try generateRecursive(
    gen, with: inputValue, context: &context, fallbackTree: innerFallback
) else { return nil }
context.sizeOverride = nil  // Defensive clear — consumed by getSize, but guard against missing getSize.
```

This is a no-op for well-formed generators (the `.getSize` handler already clears the override at line 244), but prevents leakage if the inner generator bypasses `.getSize`.

---

### Fix 4.1 — Unify checkpointing (covered by Fix 1.2)

Fix 1.2 is the immediate action. The broader encapsulation improvement (grouping mutable fields into a nested struct) is a larger refactor that should be deferred. The key safety improvement — making `runRelaxRound` use `makeSnapshot`/`restoreSnapshot` — eliminates the dual-checkpoint hazard.

---

### Fix 3.1 — Eliminate fingerprint re-flattening (covered by Fix 2.1)

Fix 2.1 changes `StructuralFingerprint.from` to accept `ChoiceSequence` instead of `ChoiceTree`, eliminating the O(n) `ChoiceSequence(tree)` allocation on every call. No separate fix needed.

---

### Fix 6.1 — Remove unused `tree` parameter from `StructuralIsolator.project`

**Priority: Low**

**File:** `StructuralIsolator.swift`

Remove the parameter from the signature and the call site:

```swift
// StructuralIsolator.swift:44-48
static func project<Output>(
    gen: ReflectiveGenerator<Output>,
    sequence: ChoiceSequence,
    bindIndex: BindSpanIndex?,
    property: @escaping (Output) -> Bool,
    isInstrumented: Bool
) -> IsolationResult<Output>? {
```

```swift
// BonsaiScheduler.swift:57-64
if let result = StructuralIsolator.project(
    gen: gen,
    sequence: state.sequence,
    bindIndex: state.bindIndex,
    property: property,
    isInstrumented: state.isInstrumented
) {
```

---

### Fix 6.2 — Skip redundant depth-0 scope when DAG covers all depth-0 positions

**Priority: Low**

**File:** `ReductionState+Bonsai.swift`

The depth-0 catch-all scope (`positionRange: nil, depth: 0`) is needed when there are depth-0 value positions not already covered by the position-ranged scopes emitted from DAG nodes. `dag.leafPositions` lists exactly these uncovered positions — `collectLeafPositions` (ChoiceDependencyGraph.swift:279-318) marks all positions inside every structural node's `positionRange` as non-leaf, so leaf positions are by definition not covered by any position-ranged scope:

```swift
// Replace unconditional append (line 1014):
scopes.append(DeletionScope(positionRange: nil, depth: 0))

// With:
let hasUncoveredDepthZeroContent = dag.leafPositions.contains { leafRange in
    bindIndex?.bindDepth(at: leafRange.lowerBound) == 0 || bindIndex == nil
}
if hasUncoveredDepthZeroContent {
    scopes.append(DeletionScope(positionRange: nil, depth: 0))
}
```

**Depth uniformity within leaf ranges:** Checking only `lowerBound` is sufficient because every leaf range has uniform bind depth. Bind depth transitions are always bracketed by `.bind(true)` / `.bind(false)` markers, which are not `.value` or `.reduced` entries. Since `collectLeafPositions` only groups contiguous `.value`/`.reduced` entries into ranges (lines 293-314), these markers always break contiguous runs at exactly the points where depth changes. A single leaf range can never straddle a bind boundary.

When all depth-0 positions fall inside structural node scope ranges, `dag.leafPositions` contains no depth-0 entries, and the catch-all is correctly skipped.

---

### Fix 6.3 — Rename `DominanceLattice` to `EncoderDominance`

**Priority: Low**

Rename the type and update all references. The doc comment should retain the categorical grounding — the 2-cell dominance relationship is real, only the "lattice" label is wrong:

```swift
/// 2-cell dominance pruning of dominated encoders within a hom-set.
///
/// Tracks categorical 2-cell dominance (Sepulveda-Jimenez, Def 15.3) across encoder
/// hom-sets. Within each hom-set (encoders sharing the same decoder), a more-aggressive
/// encoder's success makes a less-aggressive encoder's probes redundant.
/// ...
struct EncoderDominance {
```

Update all references:

- `DominanceLattice.swift` → rename struct to `EncoderDominance`
- `ReductionState.swift:101` → `var dominance: EncoderDominance`
- `Snapshot` → `let dominance: EncoderDominance`
- `makeSnapshot`/`restoreSnapshot` → update field name
- `runFibreDescent` (line 616) → `dominance.invalidate()`
- All `lattice.recordSuccess` / `lattice.shouldSkip` / `lattice.invalidate` → `dominance.*`

---

### Fix 4.2 — Document budget constant rationale

**Priority: Low**

**File:** `BonsaiScheduler.swift`

```swift
// MARK: - Budget Constants
//
// Empirically tuned on the shrinking challenge suite (March 2026).
// Ratio 6:3:1 reflects that structural changes (base descent) unlock
// more downstream value reduction than value changes alone, while
// the relax-round is speculative and should consume minimal budget.
// The total per-cycle budget (~3250 evaluations) balances reduction
// quality against wall-clock time for typical generators.

/// Per-round budget for base descent (structural minimisation).
static let baseDescentBudget = 1950

/// Per-round budget for fibre descent (value minimisation).
static let fibreDescentBudget = 975

/// Per-round budget for the relax-round when neither descent phase makes progress.
static let relaxRoundBudget = 325
```

---

### Fix 4.3 — Document encoder ordering arrays

**Priority: Low**

**File:** `ReductionState.swift`

```swift
/// Value encoder ordering for leaf-range passes in fibre descent.
/// Diverges from ``trainOrder`` via move-to-front within the leaf-range loop.
var snipOrder: [ReductionScheduler.ValueEncoderSlot] = ReductionScheduler.ValueEncoderSlot.allCases

/// Deletion encoder ordering for structural deletion in base descent.
var pruneOrder: [ReductionScheduler.DeletionEncoderSlot] = ReductionScheduler.DeletionEncoderSlot.allCases

/// Value encoder ordering for the contravariant depth sweep in fibre descent.
/// Starts identical to ``snipOrder`` each cycle; diverges via independent move-to-front.
var trainOrder: [ReductionScheduler.ValueEncoderSlot] = ReductionScheduler.ValueEncoderSlot.allCases
```

---

### Test additions for Sections 5.1-5.6

**File:** New test file `Tests/ExhaustCoreTests/Reducer/BonsaiReducerInvariantTests.swift`

Sketch of the five missing test categories:

```swift
import Testing
@testable import ExhaustCore

// MARK: - 5.1 Reducer invariant property tests
//
// No generator-of-generators exists in the codebase. These tests use a
// curated suite of hand-crafted generators at varying complexity:
// non-bind scalars, arrays, nested binds, recursive types, zips, floats.
// Each test iterates the suite with multiple seeds.

@Test(arguments: GeneratorSuite.allCases)
func shortlexMonotonicity(generator: GeneratorSuite) throws {
    // For each generator in the suite, find a failing tree,
    // run BonsaiScheduler.run, and verify the returned sequence
    // shortlex-precedes the initial sequence.
}

@Test(arguments: GeneratorSuite.allCases)
func propertyPreservedAfterReduction(generator: GeneratorSuite) throws {
    // Run BonsaiScheduler.run on each generator + property pair.
    // Verify property(reducedOutput) == false.
}

@Test(arguments: GeneratorSuite.allCases)
func materializationRoundTrip(generator: GeneratorSuite) throws {
    // For each generator, materialize a sequence, flatten to
    // ChoiceSequence, re-materialize in exact mode, and verify
    // all value entries match.
}

// MARK: - 5.2 Relax-round rollback

@Test func relaxRoundRollbackRestoresAllState() throws {
    // Set up a ReductionState where redistribution succeeds
    // (property still fails after value swap) but the full
    // base+fibre pipeline does not shortlex-improve.
    // Snapshot state before runRelaxRound.
    // Verify all fields match after rollback (including convergenceCache).
}

// MARK: - 5.3 Deep bind nesting

@Test func productSpaceAdaptiveWithFourBinds() throws {
    // Create a generator with four independent data-dependent binds.
    // Run BonsaiScheduler.run and verify all four bind-inner values
    // reach their reduction targets.
}

@Test func deltaDebugPartitioningConverges() throws {
    // Directly exercise ProductSpaceAdaptiveEncoder with k=5 axes,
    // feeding it a sequence where only a specific subset of axes
    // can be halved while preserving the property.
    // Verify the encoder discovers the maximal accepted subset.
}

// MARK: - 5.4 Convergence cache across structural changes

@Test func convergenceCacheInvalidatedOnStructuralChange() throws {
    // Populate convergence cache entries at specific indices.
    // Call accept(result, structureChanged: true).
    // Verify all entries are cleared.
}

@Test func convergenceCacheSiblingInvalidation() throws {
    // Populate convergence cache for indices in the same bind region.
    // Simulate a value change at one index.
    // Call invalidateConvergenceCacheSiblings.
    // Verify sibling entries are cleared, entries outside the region are preserved.
}

// MARK: - 5.5 Regime detector

@Test func eliminationRegimeSkipsRetries() throws {
    // Create a generator with a bind-inner value where zeroing the inner
    // value preserves the property failure. Verify the regime probe classifies
    // as elimination and skips the four PRNG retry rounds.
}

@Test func valueSensitiveRegimeProceeds() throws {
    // Create a generator where zeroing the bind-inner value causes the
    // property to pass. Verify the regime probe classifies as value-sensitive
    // and all four retries execute.
}

@Test func unknownRegimeOnRangeViolation() throws {
    // Create a generator where zeroing the bind-inner value produces
    // a bound region whose range excludes the zeroed target. Verify
    // the regime probe classifies as unknown and retries proceed.
}

// MARK: - 5.6 Fingerprint collision

@Test func compensatingDepthSumProducesDifferentFingerprint() throws {
    // Construct two ChoiceSequences with the same width and total
    // bind depth sum, but different per-position distributions.
    // Verify StructuralFingerprint distinguishes them (after Fix 2.1).
}
```
