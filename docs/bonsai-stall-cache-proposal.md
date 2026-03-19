# Implementation Plan: Stall Cache and Lift Report

Subsumes `docs/bonsai-stall-cache-proposal.md`. Grounded in the actual codebase as of this branch.

---

## Context

Every fibre descent pass re-discovers per-coordinate failure boundaries from scratch. `BinarySearchStepper` converges when `lo >= hi`, producing a stall point — the smallest value at which the property still fails for that coordinate. This stall point is discarded when the encoder finishes. On the next cycle, a fresh stepper is constructed from `(reductionTarget, currentValue)` with no memory of the previous convergence.

Separately, `ReductionMaterializer` in guided mode classifies each coordinate as tier 1 (prefix carry-forward), tier 2 (fallback tree), or tier 3 (PRNG) — then discards the classification. This information could drive smarter cache invalidation and inform the regime probe.

The goal: cache stall points across cycles and expose materializer tier classifications, reducing redundant binary search work and enabling finer-grained invalidation.

---

## Phase 0: Instrumentation

**Goal:** Measure whether the cache is worth building before building it.

### What to measure

1. **Stall frequency** — how often does each binary search encoder stall (converge without reaching the reduction target)?
2. **Stall stability** — when fibre descent runs again next cycle, how often is the new stall point within 1 of the previous one?
3. **Cycle count** — how many fibre descent passes occur per reduction run?

### Implementation

Add a `StallInstrumentation` struct to `ReductionState`:

```swift
struct StallInstrumentation {
    struct StallRecord {
        let coordinateIndex: Int
        let stallValue: UInt64
        let cycle: Int
    }
    var records: [StallRecord] = []
}
```

**Population sites** — at convergence in each encoder's `nextProbe()` path:

| Encoder | Convergence site | File |
|---------|-----------------|------|
| `BinarySearchToSemanticSimplestEncoder` | When `advanceBinarySearch()` returns nil (transition to cross-zero or next target) | `BinarySearchToSemanticSimplestEncoder.swift:145-148` |
| `BinarySearchToRangeMinimumEncoder` | When stepper returns nil in `nextProbe()` loop | `BinarySearchToRangeMinimumEncoder.swift:100` |
| `ReduceFloatEncoder` | When stepper returns nil in stages 2 and 3 | `ReduceFloatEncoder.swift:331,412` |
| `RedistributeByTandemReductionEncoder` | When `MaxBinarySearchStepper.advance()` returns nil | `RedistributeByTandemReductionEncoder.swift:133` |

**Analysis:** After a reduction run, compute:
- `stallFrequency = stalls / totalEncoderInvocations`
- `stallStability = count(|stall[cycle N] - stall[cycle N-1]| <= 1) / count(matched pairs)`
- `cycleCount = max cycle number`

**Decision criteria:**
- If `stallFrequency < 0.15` → cache has little to cache; stop here.
- If `stallStability < 0.5` → boundaries shift too much between cycles; warm starts are rarely useful.
- If `cycleCount < 3` → too few reuse opportunities.

### Files to modify
- `ReductionState.swift` — add `StallInstrumentation` field
- Each encoder file above — emit record at convergence
- `BonsaiScheduler.swift` — log summary after reduction completes

### Estimated size: ~80 lines

---

## Phase 1: Conservative Stall Cache

**Goal:** Cache per-coordinate stall points. Clear the entire cache on any structural change.

### Data structures

```swift
/// A cached binary search convergence point for a single coordinate.
struct StallEntry: Sendable {
    /// The floor value: the smallest bit pattern at which the property still failed.
    let floor: UInt64
    /// The structural fingerprint when this entry was recorded.
    let fingerprint: StructuralFingerprint
}

/// Per-coordinate stall cache, keyed by flat sequence index.
/// Invalidated entirely on structural change.
struct StallCache {
    private var entries: [Int: StallEntry] = [:]

    func floor(at index: Int, fingerprint: StructuralFingerprint) -> UInt64? {
        guard let entry = entries[index], entry.fingerprint == fingerprint else {
            return nil
        }
        return entry.floor
    }

    mutating func record(index: Int, floor: UInt64, fingerprint: StructuralFingerprint) {
        entries[index] = StallEntry(floor: floor, fingerprint: fingerprint)
    }

    mutating func invalidateAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
```

### Integration: Population

Each binary search encoder, at convergence, writes the stall point to the cache. The stall point is the stepper's `lo` value at convergence (for `BinarySearchStepper`, `lo` is the floor — the lowest value the search reached before rejection forced it back up).

**`BinarySearchToSemanticSimplestEncoder`** — at line ~148, when `advanceBinarySearch()` returns nil:
```swift
// After convergence, record stall point.
if let lo = stepper.convergenceFloor {
    stallCache.record(index: target.sequenceIndex, floor: lo, fingerprint: currentFingerprint)
}
```

**`BinarySearchToRangeMinimumEncoder`** — at line ~100, same pattern.

**`ReduceFloatEncoder`** — at lines ~331 and ~412 (stages 2 and 3 convergence).

**Redistribution encoders** — defer to Phase 3 (ceiling entries; lower priority per the proposal's Section 9.2).

### Integration: Consumption

Each binary search encoder, at `start()`, checks the cache and adjusts the stepper's lower bound.

**`BinarySearchToSemanticSimplestEncoder`** — at line ~127, where the stepper is constructed:
```swift
// Current code:
let stepper = BinarySearchStepper(lo: targetBP, hi: currentBP)

// With cache:
let cachedFloor = stallCache.floor(at: seqIdx, fingerprint: currentFingerprint)
let effectiveLo = cachedFloor ?? targetBP
let stepper = BinarySearchStepper(lo: effectiveLo, hi: currentBP)
```

If `effectiveLo > currentBP`, the stepper converges immediately (one confirmation probe). If the cached floor is stale (the true boundary has moved lower), the encoder discovers this within one probe — the first candidate at `cachedFloor` is accepted, and the search continues downward past it. **No correctness risk.**

**`BinarySearchToRangeMinimumEncoder`** — at line ~72, same pattern.

**`ReduceFloatEncoder`** — at stage 2/3 stepper construction.

### Integration: Invalidation

**In `ReductionState.accept()`** (line ~108), when `structureChanged == true`:
```swift
if structureChanged {
    spanCache.invalidate()
    stallCache.invalidateAll()  // <-- new
    bindIndex = hasBind ? BindSpanIndex(from: sequence) : nil
}
```

This is the conservative strategy. Every structural acceptance clears the entire cache.

### Integration: Threading

The `StallCache` must be accessible to encoders. Options:

**Option A (recommended):** Add `stallCache` as a field on `ReductionState`, alongside `spanCache` and `rejectCache`. Pass the current `StructuralFingerprint` to encoders via their `start()` method (add a parameter).

**Option B:** Pass the cache as an `inout` parameter through `runAdaptive()`. More explicit but requires changing the `AdaptiveEncoder` protocol.

Option A is simpler — `ReductionState` already owns the other caches, and encoders already receive their targets through `start()`.

### Coordinate identity problem

Flat sequence indices shift when structural deletions shorten the sequence. Under conservative invalidation, this is a non-issue: the cache is cleared on every structural change. But it means a stall entry recorded at index 17 is only valid until the next structural acceptance.

Within a single fibre descent pass (no structural changes allowed, enforced by the fingerprint guard), indices are stable. Between cycles, if base descent made no structural progress, indices are also stable. The conservative strategy is correct by construction.

### Files to modify
- `ReductionState.swift` — add `StallCache` field, clear in `accept()`
- `BinarySearchToSemanticSimplestEncoder.swift` — read/write cache at start/convergence
- `BinarySearchToRangeMinimumEncoder.swift` — same
- `ReduceFloatEncoder.swift` — same for stages 2 and 3
- `AdaptiveProbeStepper.swift` — expose `convergenceFloor` (the `lo` value at convergence) on `BinarySearchStepper`

### Estimated size: ~150 lines across 5 files

---

## Phase 2: Lift Report

**Goal:** Expose the materializer's per-coordinate resolution tier classification.

### Data structures

```swift
enum ResolutionTier: UInt8, Sendable {
    case exactCarryForward = 0   // Tier 1: prefix value consumed and fit
    case fallbackTree = 1        // Tier 2: fallback tree substitution
    case prng = 2                // Tier 3: random generation
}

struct LiftReport: Sendable {
    /// Per-coordinate resolution tier, indexed by flat sequence position in the NEW sequence.
    private var tiers: [Int: ResolutionTier] = [:]

    mutating func record(index: Int, tier: ResolutionTier) {
        tiers[index] = tier
    }

    func tier(at index: Int) -> ResolutionTier? {
        tiers[index]
    }

    /// Fraction of coordinates resolved by exact carry-forward.
    var fidelity: Double {
        guard tiers.isEmpty == false else { return 0 }
        let tier1Count = tiers.values.count(where: { $0 == .exactCarryForward })
        return Double(tier1Count) / Double(tiers.count)
    }
}
```

### Integration: Population

In `ReductionMaterializer.handleChooseBits()` (~line 396-442), the three code paths already determine the tier. Add a `liftReport` field to `Context` and record the tier at each value site:

```swift
// Tier 1 path (line ~398-420):
context.liftReport?.record(index: context.sequencePosition, tier: .exactCarryForward)

// Tier 2 path (line ~434-435):
context.liftReport?.record(index: context.sequencePosition, tier: .fallbackTree)

// Tier 3 path (line ~437):
context.liftReport?.record(index: context.sequencePosition, tier: .prng)
```

The lift report is populated only for `.guided` mode materializations. `.exact` mode doesn't need it (no fallback/PRNG paths). `.generate` mode doesn't need it (all PRNG by definition).

### Integration: Return type

Extend `ReductionMaterializer.Result`:

```swift
public enum Result<Output> {
    case success(value: Output, tree: ChoiceTree, liftReport: LiftReport?)
    case rejected
    case failed
}
```

The `liftReport` is `nil` for `.exact` mode and populated for `.guided` mode.

### Integration: Consumers

**Consumer 1 — Diagnostics (immediate value):**
In `SequenceDecoder.decodeGuided()` (~line 90-127), log the fidelity score:
```swift
case let .success(output, freshTree, liftReport):
    // Log: "Guided materialization fidelity: \(liftReport?.fidelity ?? 0)"
```

**Consumer 2 — Stall cache invalidation (Phase 3):** See next section.

**Consumer 3 — Regime probe (future):** The aggregate fidelity score could gate whether a guided candidate is worth testing. Below a threshold, skip the property evaluation and proceed to PRNG retries. Deferred — requires empirical calibration of the threshold.

### Files to modify
- `ReductionMaterializer.swift` — add `liftReport` to `Context`, record tiers in `handleChooseBits`, extend `Result`
- `SequenceDecoder.swift` — propagate `liftReport` through `decodeGuided`
- New file: `LiftReport.swift` (types only)

### Estimated size: ~100 lines

---

## Phase 3: Materialiser-Informed Invalidation

**Goal:** Replace conservative cache clearing with selective eviction based on the lift report.

### Design

On structural acceptance in guided mode, the materializer produces a `LiftReport`. Instead of clearing the entire stall cache, evict only entries for coordinates resolved by tier 2 or 3:

```swift
func invalidateFromLiftReport(_ report: LiftReport) {
    for (index, tier) in report.allEntries {
        if tier != .exactCarryForward {
            entries.removeValue(forKey: index)
        }
    }
}
```

Tier-1 coordinates were carried forward unchanged — their stall points are likely still valid.

### The reindexing problem

When a structural deletion shortens the sequence, flat indices shift. A stall entry at old-index 17 may correspond to new-index 14 after a 3-entry deletion. The lift report is indexed by NEW-sequence position, but the stall cache is indexed by OLD-sequence position.

**Solution:** When the materializer performs guided replay, it already knows the mapping between old and new positions (the cursor tracks its position in the old sequence while building the new tree). Extend the lift report to include the old-to-new index mapping:

```swift
struct LiftReport {
    var tiers: [Int: ResolutionTier]          // keyed by NEW index
    var oldToNew: [Int: Int]                  // old sequence index → new sequence index
}
```

On invalidation:
1. Build the new stall cache by iterating the old cache.
2. For each old entry, look up `oldToNew[oldIndex]`.
3. If the mapping exists AND the tier at the new index is `.exactCarryForward`, carry the entry forward (with updated index).
4. Otherwise, evict.

### DAG-aware invalidation (alternative to materialiser-informed)

Uses `ChoiceDependencyGraph` to determine which coordinates are reachable from the changed structure. Coordinates with no dependency path to the change retain their cached floors.

The DAG already exists and is rebuilt after each structural change in `runBaseDescent()`. The reachability query is straightforward (walk `DependencyNode.dependents` from the changed node). However, DAG-aware invalidation is strictly less precise than materialiser-informed (it evicts coordinates that COULD be affected; materialiser-informed evicts only those that WERE affected). Both require solving the reindexing problem.

**Recommendation:** Skip DAG-aware and go directly from conservative (Phase 1) to materialiser-informed (Phase 3). The materialiser-informed strategy uses information that's already computed (the lift report); the DAG-aware strategy requires additional reachability computation for a strictly inferior result.

### Files to modify
- `StallCache` — add `invalidateFromLiftReport(_:)` method
- `ReductionMaterializer.swift` — populate `oldToNew` mapping in `Context`
- `ReductionState.swift` — call `invalidateFromLiftReport` instead of `invalidateAll` when a lift report is available

### Estimated size: ~100 lines

---

## Phase 4: Ceiling Entries and Redistribution (Future)

**Goal:** Cache redistribution encoder stall points (ceiling entries for absorber coordinates).

Lower priority. Redistribution runs once at the end of fibre descent, so ceilings have low reuse frequency. Worth measuring via Phase 0 instrumentation before committing.

| Encoder | Stall type | Site |
|---------|-----------|------|
| `RedistributeAcrossValueContainersEncoder` | FindIntegerStepper convergence per pair orientation | `RedistributeAcrossValueContainersEncoder.swift:278-280` |
| `RedistributeByTandemReductionEncoder` | MaxBinarySearchStepper convergence per plan | `RedistributeByTandemReductionEncoder.swift:133` |

---

## Phase 5: Regime Probe Enhancement (Future)

**Goal:** Use aggregate lift fidelity to skip low-confidence guided evaluations.

When the fidelity score from the lift report is below a threshold, skip the guided property evaluation and proceed to PRNG retries. Saves one materialization + one property invocation per low-fidelity structural reduction.

**Integration point:** `runJointBindInnerReduction()` in `ReductionState+Bonsai.swift`, where each bind-inner candidate triggers guided replay.

**Calibration:** The threshold depends on property sensitivity. Start with a fixed threshold (for example, 0.5), measure the acceptance rate at each fidelity level across the test suite, and adjust. Alternatively, make it adaptive: start high, lower when high-fidelity candidates are scarce.

Deferred until the lift report is stable and instrumentation data guides threshold selection.

---

## Expected Impact (Revised)

| Scenario | Probe savings | Total budget impact |
|----------|--------------|-------------------|
| 50+ independent coordinates, 10+ cycles, few structural changes | ~60-80% of fibre descent probes | ~15-25% total |
| 5-15 coordinates, 5-10 cycles, moderate structural changes | ~20-40% of fibre descent probes in stable cycles | ~5-10% total |
| 1-3 coordinates, frequent structural changes, high coupling | Near zero | ~0% (small overhead) |
| Post-relax-round with 2 perturbed coordinates out of 50 | ~96% of coordinates get warm starts | Significant per-relax-round |

The lift report adds diagnostic value independently of the stall cache.

---

## Verification

### Phase 0 (Instrumentation)
- Run the existing test suite with instrumentation enabled.
- Check that stall records are emitted and the summary statistics are plausible.
- Decision gate: proceed to Phase 1 only if stall frequency > 15% and stability > 50%.

### Phase 1 (Conservative Cache)
- Unit test: construct a `StallCache`, record entries, verify `floor(at:fingerprint:)` returns them, verify `invalidateAll()` clears them.
- Integration test: run a reduction on a generator with 10+ independent integer coordinates. Compare probe counts with and without the cache. Expect fewer total probes with the cache (at least on cycles 2+).
- Correctness check: the reduced output must be identical with and without the cache (the cache is a pure optimization; it must not change the final result).

### Phase 2 (Lift Report)
- Unit test: run `ReductionMaterializer.materialize()` in guided mode with a known prefix and fallback tree. Verify the lift report classifies each coordinate correctly.
- Unit test: verify `fidelity` computation (all tier 1 → 1.0, all tier 3 → 0.0, mixed → correct ratio).

### Phase 3 (Materialiser-Informed Invalidation)
- Unit test: verify that `invalidateFromLiftReport` retains tier-1 entries and evicts tier-2/3 entries.
- Unit test: verify old-to-new index remapping after a structural deletion.
- Integration test: same as Phase 1 but with materialiser-informed invalidation. Expect higher cache hit rates (fewer false evictions) compared to conservative.

---

## Key Files

| File | Role |
|------|------|
| `ReductionState.swift` | Owns the stall cache; clears on structural acceptance |
| `AdaptiveProbeStepper.swift` | `BinarySearchStepper` — expose `lo` at convergence |
| `BinarySearchToSemanticSimplestEncoder.swift` | Read/write cache at start/convergence |
| `BinarySearchToRangeMinimumEncoder.swift` | Same |
| `ReduceFloatEncoder.swift` | Same for stages 2 and 3 |
| `ReductionMaterializer.swift` | Populate lift report in `handleChooseBits` |
| `SequenceDecoder.swift` | Propagate lift report through decode path |
| `BonsaiScheduler.swift` | Phase 0 instrumentation logging |
| `ChoiceDependencyGraph.swift` | `StructuralFingerprint` used as cache generation counter |
