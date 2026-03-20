# Implementation Plan: Stall Cache and Lift Report

Subsumes `docs/bonsai-stall-cache-proposal.md`. Grounded in the actual codebase as of this branch.

---

## Context

Every fibre descent pass re-discovers per-coordinate failure boundaries from scratch. `BinarySearchStepper` converges when `lo >= hi`, producing a stall point — the smallest value at which the property still fails for that coordinate. At convergence, `lo == hi == bestAccepted`: `hi` is set to the last accepted probe, `lo` catches up via `lo = lastProbe + 1`. This stall point is discarded when the encoder finishes. On the next cycle, a fresh stepper is constructed from `(reductionTarget, currentValue)` with no memory of the previous convergence.

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

Only allocate when `isInstrumented == true`.

**Population sites** — at convergence in each encoder's `nextProbe()` path, record `bestAccepted` (already exposed as `private(set)` on both `BinarySearchStepper` and `FindIntegerStepper`):

| Encoder | Convergence site | Value to record |
|---------|-----------------|-----------------|
| `BinarySearchToSemanticSimplestEncoder` (downward) | When `advanceBinarySearch()` returns nil (transition to cross-zero or next target) | `stepper.bestAccepted` — floor (`BinarySearchToSemanticSimplestEncoder.swift:148`) |
| `BinarySearchToSemanticSimplestEncoder` (upward) | Same convergence site, upward `MaxBinarySearchStepper` case | `stepper.bestAccepted` — ceiling (`BinarySearchToSemanticSimplestEncoder.swift:148`) |
| `BinarySearchToRangeMinimumEncoder` | When stepper returns nil in `nextProbe()` loop | `stepper.bestAccepted` (`BinarySearchToRangeMinimumEncoder.swift:100`) |
| `ReduceFloatEncoder` | When `FindIntegerStepper` returns nil in stages 2 and 3 | `UInt64(stepper.bestAccepted)` (`ReduceFloatEncoder.swift:331,412`) |

The upward case (`MaxBinarySearchStepper`) applies when `currentBP < targetBP` — for example, signed types where the current value's bit pattern is below the semantic simplest's bit pattern. At convergence, `bestAccepted` is a ceiling (largest accepted value), not a floor. Both directions are instrumented and cached using typed `WarmStart` records (see below).

Note: `ReduceFloatEncoder` stages 2-3 use `FindIntegerStepper`, which searches *quantum space* — the largest integer `k` such that moving `k * minDelta` from the current value is accepted. The stepper's `bestAccepted` is a quantum count (`Int`), not a bit pattern. A `UInt64` bit-pattern floor cannot be translated into a quantum bound without recomputing the current value's ULP, `minDelta`, and movement direction — context that is stage-specific and changes when the float value changes. Float convergence points are therefore excluded from the quantum warm-start mechanism. The float encoder uses the warm start's `bound` field for change detection only (stage-skip), ignoring `direction`. Phase 0 instruments float convergence for observability: to measure how often float encoders stall and whether quantum stability exists.

Redistribution encoders (`RedistributeByTandemReductionEncoder`, `RedistributeAcrossValueContainersEncoder`) are excluded from instrumentation. Redistribution runs once at the end of fibre descent, so convergence points have low reuse frequency.

**WarmStart type.** A typed record that carries both the convergence bound and the search direction. This eliminates the risk of an upward ceiling being consumed as a downward floor — the encoder checks direction against its search direction and ignores mismatches.

```swift
struct WarmStart: Sendable {
    /// The convergence bound from a previous cycle.
    let bound: UInt64
    /// The search direction that produced this bound.
    let direction: Direction

    enum Direction: Sendable {
        /// Bound is a floor: the smallest accepted value (stepper `lo`).
        case downward
        /// Bound is a ceiling: the largest accepted value (stepper `hi`).
        case upward
    }
}
```

**Record harvesting.** Each encoder accumulates convergence data in a `var stallRecords: [Int: WarmStart]` field. At downward convergence, the encoder appends `(seqIdx, WarmStart(bound: stepper.bestAccepted, direction: .downward))`. At upward convergence, `(seqIdx, WarmStart(bound: stepper.bestAccepted, direction: .upward))`. For `BinarySearchToSemanticSimplestEncoder`, where the stepper is a `DirectionalStepper` enum, add a computed `bestAccepted` property that switches on `.downward` / `.upward` and forwards to the underlying stepper. The float encoder appends `(seqIdx, WarmStart(bound: currentBitPattern, direction: .downward))` for change detection.

`runAdaptive` takes the encoder by value (`var encoder = encoder`) and mutates the local copy. After the probe loop, it drains the encoder's `stallRecords` directly into `self.stallCache` and `self.stallInstrumentation` before the local copy goes out of scope — the same pattern as `self.rejectCache`:

```swift
func runAdaptive(
    _ encoder: some AdaptiveEncoder,
    // ... existing parameters ...
    warmStarts: [Int: WarmStart]? = nil
) throws -> Bool {
    var encoder = encoder
    encoder.start(sequence: sequence, targets: targets, warmStarts: warmStarts)
    // ... probe loop ...
    for (index, warmStart) in encoder.stallRecords {
        stallCache.record(index: index, warmStart: warmStart)
    }
    stallInstrumentation?.harvestRecords(encoder.stallRecords, cycle: currentCycle)
    return anyAccepted
}
```

No `inout` parameter needed — `runAdaptive` writes directly to `self.stallCache`, matching the existing `self.rejectCache` pattern. Call sites that produce no records (ZeroValue, ProductSpace, deletion encoders) are unaffected.

**Cycle number flow.** The cycle counter lives in `BonsaiScheduler.run()`. Store it on `ReductionState` as `var currentCycle: Int` — set by the scheduler at the top of each cycle. `runAdaptive` reads `self.currentCycle` when stamping records.

**Analysis:** After a reduction run, compute:
- `stallFrequency = stalls / totalEncoderInvocations`
- `stallStability = count(|stall[cycle N] - stall[cycle N-1]| <= 1) / count(matched pairs)`
- `cycleCount = max cycle number`

**Decision criteria:**
- If `stallFrequency < 0.15` → cache has little to cache; stop here.
- If `stallStability < 0.5` → boundaries shift too much between cycles; warm starts are rarely useful.
- If `cycleCount < 3` → too few reuse opportunities, though `maxStalls = 1` generators with high coordinate counts may still benefit from a single cycle of reuse.

### Files to modify
- `ReductionState.swift` — add `StallInstrumentation` type and field
- `BinarySearchToSemanticSimplestEncoder.swift` — add `stallRecords` field, record at convergence
- `BinarySearchToRangeMinimumEncoder.swift` — same
- `ReduceFloatEncoder.swift` — same (stages 2-3 only)
- `ReductionState.swift` (`runAdaptive`) — harvest records after encoder completes
- `BonsaiScheduler.swift` — log summary after main loop

### Estimated size: ~80 lines

---

## Phase 1: Conservative Stall Cache

**Goal:** Cache per-coordinate stall points. Clear the entire cache on any structural change.

### Data structures

```swift
/// Per-coordinate stall cache, keyed by flat sequence index.
/// Invalidated entirely on structural change.
struct StallCache {
    private var entries: [Int: WarmStart] = [:]

    func warmStart(at index: Int) -> WarmStart? {
        entries[index]
    }

    mutating func record(index: Int, warmStart: WarmStart) {
        entries[index] = warmStart
    }

    mutating func invalidateAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
```

No `StructuralFingerprint` in the entry. The conservative strategy clears the entire cache on structural change, so a per-entry fingerprint guard is redundant. Entries are valid from recording until the next structural acceptance. This also avoids a design gap that would surface in any future selective-invalidation scheme: retained entries would carry the old fingerprint and fail the guard against the new fingerprint, requiring a fingerprint-update step.

The cache stores typed `WarmStart` values. Both downward (floor) and upward (ceiling) convergence points are cached. The encoder checks the warm start's direction against its own search direction — a direction mismatch is ignored. Ceiling warm starts (Phase 4) require no cache changes — they are already stored with `.upward` direction.

### Integration: Population

Each binary search encoder, at convergence, records the stall point. The stall point is `bestAccepted` — the smallest value accepted by the property during the binary search. At convergence, `lo == hi == bestAccepted`, so this is equivalently the stepper's `lo` or `hi` value.

**`BinarySearchToSemanticSimplestEncoder`** — after `advanceBinarySearch()` returns nil (line ~148):
```swift
let target = targets[currentIndex]
let direction: WarmStart.Direction = switch target.stepper {
case .downward: .downward
case .upward: .upward
}
stallRecords[target.seqIdx] = WarmStart(bound: target.stepper.bestAccepted, direction: direction)
```

Both downward (floor) and upward (ceiling) convergence points are recorded with their direction. The consumer checks direction before use — no contamination risk.

**`BinarySearchToRangeMinimumEncoder`** — after `probeValue == nil` (line ~100). This encoder only uses `BinarySearchStepper` (downward):
```swift
let target = targets[currentIndex]
stallRecords[target.seqIdx] = WarmStart(bound: target.stepper.bestAccepted, direction: .downward)
```

**`ReduceFloatEncoder`** — at convergence of the final stage for a target (when `advanceStageOrTarget` moves to the next target or returns false), record the current bit pattern:
```swift
let target = targets[currentTargetIndex]
stallRecords[target.seqIdx] = WarmStart(bound: target.currentBitPattern, direction: .downward)
```

The float encoder records `currentBitPattern` rather than a stepper convergence value. The `bound` field is used for change detection (stage-skip), not as a search bound. The `direction` is `.downward` by convention — the float encoder ignores it on consumption.

### Integration: Consumption

The encoder does not know the cache exists. The `AdaptiveEncoder` protocol gains a `warmStarts` parameter on `start()` and a `stallRecords` property:

```swift
public protocol AdaptiveEncoder: SequenceEncoderBase {
    /// Initializes internal state for a new encoding pass.
    ///
    /// - Parameter warmStarts: Convergence data from a previous cycle, keyed by flat sequence
    ///   index. Each entry carries a bound and a direction. The encoder checks direction
    ///   against its search direction — a mismatch is ignored. `nil` when the cache is empty
    ///   or the encoder does not use warm starts.
    mutating func start(sequence: ChoiceSequence, targets: TargetSet, warmStarts: [Int: WarmStart]?)

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry is `(flatSequenceIndex, WarmStart)`. Read by ``runAdaptive`` after the
    /// probe loop to harvest records before the local encoder copy goes out of scope.
    var stallRecords: [Int: WarmStart] { get }

    // ... existing requirements ...
}

extension AdaptiveEncoder {
    /// Convenience overload for callers that do not pass warm starts.
    public mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        start(sequence: sequence, targets: targets, warmStarts: nil)
    }
    public var stallRecords: [Int: WarmStart] { [:] }
}
```

The `warmStarts` parameter replaces the property-based approach — warm starts arrive at the same moment as targets, making the data flow explicit. The two-parameter `start(sequence:targets:)` overload in the extension preserves source compatibility at existing call sites. Conformers that do not use warm starts implement `start(sequence:targets:warmStarts:)` and ignore the parameter. Conformers that use warm starts read it during target construction.

`runAdaptive` passes `warmStarts` through to `start()` and drains `stallRecords` into `self.stallCache` after the probe loop (see Record Harvesting above for the full `runAdaptive` snippet).

**Integer binary search encoders** use the warm start bound when the direction matches their search direction:

**`BinarySearchToSemanticSimplestEncoder`** — at line ~126, where the stepper is constructed:
```swift
let warmStart = warmStarts?[seqIdx]
let stepper: DirectionalStepper = if currentBP > targetBP {
    // Downward search: use floor from matching warm start.
    let effectiveLo = (warmStart?.direction == .downward ? warmStart?.bound : nil) ?? targetBP
    .downward(BinarySearchStepper(lo: effectiveLo, hi: currentBP))
} else {
    // Upward search: use ceiling from matching warm start.
    let effectiveHi = (warmStart?.direction == .upward ? warmStart?.bound : nil) ?? targetBP
    .upward(MaxBinarySearchStepper(lo: currentBP, hi: effectiveHi))
}
```

A direction mismatch (for example, an `.upward` warm start on a coordinate that is now being searched downward) is ignored — the encoder falls back to the cold-start target.

If `effectiveLo > currentBP`, the stepper converges immediately (`lo >= hi` in `start()`). Zero probes — the coordinate was already reduced to or past the warm start floor.

If `effectiveLo == currentBP`, the stepper also converges immediately. The coordinate is exactly at the floor from the previous cycle.

If `effectiveLo < currentBP`, the search runs with a narrower range than without the warm start. Fewer probes to converge.

**Staleness trade-off.** A stall point is not an intrinsic property of a coordinate — it is a property of a coordinate *in the context of all other coordinate values*. A stall at index 5 = 42 means "the property fails with value 42 at index 5 given the current values everywhere else." If other coordinates change between cycles (via value minimization at other positions, or via redistribution), the true floor at index 5 may shift.

If the true floor has moved *higher* (the property now fails at a larger value), the warm start is conservative — the search starts below the true floor and converges normally. No opportunity is missed.

If the true floor has moved *lower* (the property now fails at a smaller value), the warm start causes the search to settle at the cached floor rather than the true floor. The search range is `[cachedFloor, currentBP]`, and the stepper never probes below `cachedFloor`. This is a *missed reduction opportunity*, not an incorrect result: the accepted value is still a valid failing point, but a smaller one exists that the search cannot discover.

**Floor validation probe.** When the warm start actually narrows the search range (`effectiveLo < currentBP`), the search converges without exploring below `effectiveLo`. To detect a floor that moved lower, the encoder emits a single validation probe at `effectiveLo - 1` after convergence, guarded by three conditions:

1. `effectiveLo < currentBP` — the warm start narrowed the range. When `effectiveLo >= currentBP`, the coordinate is already at or past the floor; the stepper converged in zero probes without the warm start restricting anything, so there is nothing to validate.
2. `effectiveLo > targetBP` — there is space below the floor to check.
3. `effectiveLo > 0` — underflow guard.

```swift
// After warm-start convergence, validate the floor if the warm start narrowed the range.
if isWarmStarted, effectiveLo < currentBP, effectiveLo > targetBP, effectiveLo > 0 {
    // Probe one step below the cached floor.
    let validationProbe = effectiveLo - 1
    // Emit as a normal candidate. If accepted, the floor moved lower.
}
```

- **Rejected:** the floor is confirmed at `cachedFloor`. Done. Cost: one extra probe.
- **Accepted:** the floor has moved lower. Restart the search with `lo = targetBP, hi = cachedFloor - 1` to find the true floor.

When `effectiveLo >= currentBP` (the coordinate is at or past the cached floor), the validation probe does not fire. The coordinate was already at its floor — the stepper converged in zero probes. If the true floor has moved lower due to other coordinate changes, this is a missed opportunity bounded by conservative invalidation, the stall counter, and typically weak cross-coordinate coupling. The alternative — validating every stalled coordinate every cycle — costs one probe per stalled coordinate per cycle, halving the savings for the majority case (stable floor, value at floor) to catch a minority case.

| Scenario | Without validation | With validation |
|----------|-------------------|-----------------|
| Stable floor, value at floor | 0 probes | 0 probes (guard skips) |
| Stable floor, value above floor | log2(currentBP - cachedFloor) | log2(currentBP - cachedFloor) + 1 |
| Floor moved lower, value above floor | Missed (settles at stale floor) | 1 + log2(cachedFloor - targetBP) to find true floor |
| Floor moved lower, value at floor | Missed (zero probes) | Missed (guard skips — same staleness trade-off) |
| Cold start (no cache) | log2(currentBP - targetBP) | log2(currentBP - targetBP) |

The validation probe fires only when the warm start narrowed the range. Zero overhead for stalled coordinates that are already at their floor.

**Validation probe placement in the state machine.** The validation probe must be emitted after the warm-start stepper converges but before the encoder transitions to the next target or phase. This requires a new state in each encoder:

**`BinarySearchToRangeMinimumEncoder`:** After the stepper returns nil (line ~100), before incrementing `currentIndex`. Add a `var pendingValidation: (seqIdx: Int, floor: UInt64, targetBP: UInt64)?` field. When the stepper converges on a warm-started coordinate, set `pendingValidation` and emit the validation probe on the next `nextProbe()` call. If accepted (floor moved lower), restart with a cold stepper `BinarySearchStepper(lo: targetBP, hi: floor - 1)`. If rejected, clear `pendingValidation` and advance to the next target.

**`BinarySearchToSemanticSimplestEncoder`:** After `advanceBinarySearch()` returns nil (line ~148), before entering the cross-zero phase or advancing to the next target. The validation probe runs *before* cross-zero — if the floor has moved lower, the cross-zero starting point (derived from `bestAccepted`) is wrong. Add a `.validatingFloor` case to the `searchPhase` enum, entered after warm-start binary search convergence. The `.validatingFloor` state emits the validation probe, then transitions to `.crossZero` or `advanceToNextTarget()` based on the result.

**`BinarySearchToRangeMinimumEncoder`** — at line ~72, same pattern. This encoder only uses `BinarySearchStepper` (downward), so it checks for `.downward` direction:
```swift
let effectiveLo: UInt64 = if let warmStart = warmStarts?[seqIdx], warmStart.direction == .downward {
    warmStart.bound
} else {
    targetBP
}
stepper: BinarySearchStepper(lo: effectiveLo, hi: currentBP)
```

**`ReduceFloatEncoder`** — at target construction in `start()`, when the warm start bit pattern matches the current bit pattern, the value has not changed since the previous convergence. Stages 0 (special values) and 1 (truncation) are batch stages that would produce the same rejected candidates. Skip to stage 2 (integral binary search):

```swift
if let warmStart = warmStarts?[seqIdx],
   warmStart.bound == v.choice.bitPattern64
{
    // Value unchanged since last convergence — skip batch stages.
    stage = .integralBinarySearch
}
```

The skip target is `.integralBinarySearch` unconditionally, even for non-integral floats. For non-integral values, `prepareIntegralBinarySearch` returns without setting `binarySearchMaxQuantum`, and `nextIntegralBinarySearchCandidate` returns nil immediately (`guard binarySearchMaxQuantum > 0`). The existing `advanceStageOrTarget()` then advances to `.ratioBinarySearch`. No branching on float type is needed.

Same staleness trade-off as the integer encoders: other coordinates may have changed between cycles, making previously-rejected batch candidates (like zero) now acceptable. Skipping stages 0-1 misses that opportunity. But batch stages are the lowest-yield part of the float pipeline — if zero or a special value is accepted, it typically succeeds on the first cycle. The savings are ~20 materializations per float target per cycle.

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

### Integration: Snapshot

`Snapshot` captures all mutable state for rollback (relax-round failure, fingerprint guard). Include `stallCache` in the snapshot, alongside `spanCache` and `lattice`. Without snapshotting, a failed relax-round rolls back the sequence but leaves stall entries from the redistributed state — every coordinate would pay a validation probe plus potential cold restart on the next fibre descent, negating the cache's benefit. Snapshotting the cache restores entries that match the restored sequence.

```swift
struct Snapshot {
    // ... existing fields ...
    let stallCache: StallCache
}
```

### Integration: Cache ownership and flow

The `StallCache` lives on `ReductionState`, alongside `spanCache` and `rejectCache`. Encoders never see the cache.

**Before calling `runAdaptive`:** the caller builds the `warmStarts` dictionary from the cache by querying `stallCache.warmStart(at:)` for each target coordinate. This dictionary is passed to `runAdaptive`, which sets it on the encoder before `start()`.

**After the probe loop:** `runAdaptive` drains `encoder.stallRecords` directly into `self.stallCache` and `self.stallInstrumentation` before the local encoder copy goes out of scope. No `inout` parameter — same pattern as `self.rejectCache`:

```swift
try runAdaptive(
    binarySearchToZeroEncoder, decoder: decoder,
    targets: .spans(leafSpans), structureChanged: structureChanged,
    budget: &legBudget, warmStarts: cachedWarmStarts
)
// stallCache updated internally by runAdaptive
```

### Coordinate identity problem

Flat sequence indices shift when structural deletions shorten the sequence. Under conservative invalidation, this is a non-issue: the cache is cleared on every structural change. But it means a stall entry recorded at index 17 is only valid until the next structural acceptance.

Within a single fibre descent pass (no structural changes allowed, enforced by the fingerprint guard), indices are stable. Between cycles, if base descent made no structural progress, indices are also stable. The conservative strategy is correct by construction.

### `maxStalls = 1` interaction

With `fast` mode (`maxStalls = 1`), there are at most two cycles. The second cycle is the stall-detection cycle — it runs fibre descent to confirm that no further progress is possible, then exits. Without the cache, this confirmation re-runs the full binary search at every coordinate, rediscovering the same floors at O(log(range)) probes each. With the cache, each stalled coordinate's stepper sees `lo >= hi` immediately (zero probes) — the stall-detection cycle becomes a confirmation pass rather than a full re-exploration.

For 50 coordinates with 64-bit ranges, the savings are up to O(log(range)) × stalled_coordinate_count ≈ 64 × 50 = 3200 probes. The validation probe fires only when `effectiveLo < currentBP` (the warm start narrowed the range), which does not apply to stalled coordinates already at their floor — so the confirmation pass is genuinely zero-cost per coordinate.

For small generators (fewer than five coordinates), the dictionary overhead may exceed the savings. Phase 0 instrumentation will settle this.

### Relax-round cache lifecycle

Relax rounds redistribute values without structural changes. The conservative cache does not clear on value changes. After redistribution:

- The *absorber* coordinate's value increased — its cached floor is still a valid lower bound for future search. The stepper searches `[cachedFloor, newHigherValue]`, which is a wider range than without redistribution but still skips the region below the cached floor.
- The *donor* coordinate's value decreased (often to zero) — its cached floor is irrelevant. The stepper sees `lo >= hi` (the coordinate is already at or below the floor) and converges immediately.

No special handling needed.

### Files to modify
- `ReductionState.swift` — add `StallCache` and `WarmStart` types; add `stallCache` and `currentCycle` fields; clear in `accept()`; include in `Snapshot`; harvest `stallRecords` in `runAdaptive`
- `SequenceEncoder.swift` — change `AdaptiveEncoder.start()` to accept `warmStarts` parameter; add `stallRecords` declaration with default extension; add two-parameter `start()` convenience overload
- `BinarySearchToSemanticSimplestEncoder.swift` — use `warmStarts` at stepper construction; add `.validatingFloor` state; add `stallRecords` field, record at convergence
- `BinarySearchToRangeMinimumEncoder.swift` — same (no cross-zero, simpler validation placement)
- `ReduceFloatEncoder.swift` — use warm start for stage-skip; add `stallRecords` field, record bit pattern at convergence
- `ReductionState+Bonsai.swift` — build `warmStarts` from cache before `runAdaptive`; harvest `stallRecords` after; pass cycle number to `runFibreDescent`
- `BonsaiScheduler.swift` — pass cycle number to `runFibreDescent`

### Estimated size: ~150 lines across 7 files

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
    /// Tier counts for fidelity computation.
    private var tierOnCount = 0
    private var tierTwoCount = 0
    private var tierThreeCount = 0

    mutating func record(tier: ResolutionTier) {
        switch tier {
        case .exactCarryForward: tierOnCount += 1
        case .fallbackTree: tierTwoCount += 1
        case .prng: tierThreeCount += 1
        }
    }

    /// Fraction of coordinates resolved by exact carry-forward.
    var fidelity: Double {
        let total = tierOnCount + tierTwoCount + tierThreeCount
        guard total > 0 else { return 0 }
        return Double(tierOnCount) / Double(total)
    }

    var totalCount: Int { tierOnCount + tierTwoCount + tierThreeCount }
}
```

### Integration: Population

In `ReductionMaterializer.handleChooseBits()` (~line 396-442), the three code paths already determine the tier. Add a `liftReport` field to `Context` and record the tier at each value site:

```swift
case .guided:
    if let prefixValue = context.cursor.tryConsumeValue() {
        // Tier 1: prefix carry-forward.
        context.liftReport?.record(tier: .exactCarryForward)
        let bp = prefixValue.choice.bitPattern64
        randomBits = Swift.min(Swift.max(bp, min), max)
        // ...
    } else if let calleeFallback, case let .choice(value, _) = calleeFallback {
        // Tier 2: fallback tree substitution.
        context.liftReport?.record(tier: .fallbackTree)
        randomBits = Swift.min(Swift.max(value.bitPattern64, min), max)
    } else {
        // Tier 3: PRNG.
        context.liftReport?.record(tier: .prng)
        randomBits = context.prng.next(in: min ... max)
    }
```

The lift report is populated only for `.guided` mode materializations. `.exact` mode does not need it (no fallback/PRNG paths). `.generate` mode does not need it (all PRNG by definition).

Phase 2's only consumer is the `fidelity` score — a ratio of tier counts. Per-coordinate keying (mapping each coordinate to its resolution tier) is only needed for Phase 3's selective invalidation (deferred). Using counters instead of a dictionary avoids the index-semantics question entirely: no key space, no ambiguity about old vs new vs candidate sequence positions.

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
In `SequenceDecoder.decodeGuided()` (~line 90-127), log the fidelity score when instrumented:
```swift
case let .success(output, freshTree, liftReport):
    if isInstrumented, let report = liftReport {
        ExhaustLog.debug(
            category: .reducer,
            event: "guided_materialization_fidelity",
            metadata: ["fidelity": "\(report.fidelity)"]
        )
    }
```

**Consumer 2 — Regime probe (future, deferred):** The aggregate fidelity score could gate whether a guided candidate is worth testing. Below a threshold, skip the property evaluation and proceed to PRNG retries. Deferred — requires empirical calibration of the threshold.

### Files to modify
- `ReductionMaterializer.swift` — add `liftReport` to `Context`, record tiers in `handleChooseBits`, extend `Result`
- `SequenceDecoder.swift` — propagate `liftReport` through `decodeGuided`
- New file: `LiftReport.swift` (types only)

### Estimated size: ~100 lines

---

## Deferred Phases

### Phase 3: Materialiser-Informed Invalidation (Deferred)

**Goal:** Replace conservative cache clearing with selective eviction based on the lift report.

Deferred for three reasons:

1. **Reindexing complexity.** When a structural deletion shortens the sequence, flat indices shift. A stall entry at old-index 17 may correspond to new-index 14. Building the `oldToNew` mapping requires threading a flat-position counter through the recursive materializer (1200 lines, tree-space emission). The materializer works in tree space; flat sequence indices are determined post-hoc during flattening. Missing one counter increment breaks the mapping. If pursued, the counter should be encapsulated in a `PositionTracker` struct rather than scattered across emission sites.

2. **Fingerprint guard gap.** The conservative cache avoids per-entry fingerprints (entries are simply cleared on structural change). A selective-invalidation scheme that retains entries must update their fingerprints to match the new structure, or the `floor(at:fingerprint:)` guard rejects them all. This is a design gap that must be resolved before Phase 3 can proceed.

3. **Empirical justification missing.** Phase 0 must show that structural changes are both frequent enough to invalidate the conservative cache often *and* small enough that tier-1 retention is meaningful. If structural changes are rare, the conservative cache already survives most cycles. If structural changes are large, most coordinates are tier 2-3 and selective retention preserves little.

### Phase 4: Ceiling Entries and Redistribution (Deferred)

**Goal:** Cache redistribution encoder stall points (ceiling entries for absorber coordinates).

Lower priority. Redistribution runs once at the end of fibre descent, so ceilings have low reuse frequency. Worth measuring via Phase 0 instrumentation before committing.

Note: the `WarmStart` type and `StallCache` already store upward (ceiling) convergence points with `.upward` direction. `BinarySearchToSemanticSimplestEncoder` already records upward convergence. Enabling ceiling warm starts for the upward search path requires no cache or type changes — only consuming the `.upward` entries in the upward stepper construction, which the current code already does.

### Phase 5: Regime Probe Enhancement (Deferred)

**Goal:** Use aggregate lift fidelity to skip low-confidence guided evaluations.

Deferred until the lift report is stable and instrumentation data guides threshold selection.

---

## Expected Impact

| Scenario | Probe savings | Total budget impact |
|----------|--------------|-------------------|
| 50+ independent coordinates, 10+ cycles, few structural changes | ~60-80% of fibre descent probes | ~15-25% total |
| 5-15 coordinates, 5-10 cycles, moderate structural changes | ~20-40% of fibre descent probes in stable cycles | ~5-10% total |
| 1-3 coordinates, frequent structural changes, high coupling | Near zero | ~0% (small overhead) |
| Post-relax-round with 2 perturbed coordinates out of 50 | ~96% of coordinates get warm starts | Significant per-relax-round |
| `maxStalls = 1`, 50+ coordinates, stable stalls | ~3200 probes saved (full re-exploration → zero-cost confirmation) | Eliminates nearly all cycle 2 fibre descent cost |

The lift report adds diagnostic value independently of the stall cache.

---

## Verification

### Phase 0 (Instrumentation)
- Run the existing test suite with instrumentation enabled.
- Check that stall records are emitted and the summary statistics are plausible.
- Decision gate: proceed to Phase 1 only if stall frequency > 15% and stability > 50%.

### Phase 1 (Conservative Cache)

**Unit tests:**
- Construct a `StallCache`, record entries, verify `floor(at:)` returns them, verify `invalidateAll()` clears them.
- Verify the validation probe: after warm-start convergence at `cachedFloor`, a probe at `cachedFloor - 1` is emitted. If accepted, the encoder restarts with `lo = targetBP`.

**Integration test:**
- Run a reduction on a generator with 10+ independent integer coordinates. Compare probe counts with and without the cache. Expect fewer total probes with the cache (at least on cycles 2+).

**Correctness check:**
- The reduced output must be identical with and without the cache. The validation probe ensures the encoder always discovers the true floor — the cache is a pure performance optimization that must not change the final result. Any divergence in shrink output between cached and uncached runs is a bug.

### Phase 1 — Savings Verification

The stall cache should produce a measurable reduction in fibre descent probe count. The following signals confirm the cache is working. Absence of these signals indicates the cache is not providing value and should be re-evaluated.

**Instrumentation.** Add three counters to `ReductionState`, emitted at the end of each cycle via `bonsai_cycle_end`:

1. `warm_start_hits` — number of coordinates where a warm start was provided and the stepper converged in zero or one probes (immediate convergence or validation-only).
2. `warm_start_restarts` — number of coordinates where the validation probe was accepted (floor moved lower), triggering a cold restart.
3. `cold_starts` — number of coordinates where no warm start was available (cache miss or first cycle).

**Expected signals by scenario:**

*50+ independent coordinates, stable stalls, `maxStalls = 8`:*
- Cycle 1: `cold_starts ≈ 50`, `warm_start_hits = 0`. No cache entries yet.
- Cycle 2+: `warm_start_hits ≈ 45-50`, `cold_starts ≈ 0-5` (only coordinates that made progress last cycle). `warm_start_restarts ≈ 0-2`.
- Total fibre descent probes in cycle 2 should be ~80% fewer than cycle 1.
- If `warm_start_hits` is consistently below 30% of coordinates, the cache is not helping — stall points are unstable.

*Few coordinates (3-5), frequent structural changes:*
- `cold_starts` dominates (cache cleared each cycle by structural changes).
- `warm_start_hits ≈ 0`.
- Total probe count should be approximately equal to uncached. Overhead is three counter increments per coordinate — negligible.

*Post-relax-round:*
- Redistribution changes 2 coordinates, leaves the rest unchanged.
- `warm_start_hits ≈ n - 2` (all undisturbed coordinates).
- `warm_start_restarts ≈ 0-2` (the redistributed coordinates may have stale floors if they were donors/absorbers in a previous cycle, but their values changed so the cache entry either converges immediately or the validation probe catches it).

**Red flags — signals that the cache is harmful:**

- `warm_start_restarts` consistently exceeds 20% of `warm_start_hits`. This means floors are shifting frequently between cycles — the validation probe catches it, but the cold restart after validation costs more than a cold start would have. The cache is adding probes, not saving them.
- Shrink output differs between cached and uncached runs on the same seed. This should not happen with the validation probe and indicates a bug.
- Total reduction time increases with the cache enabled. Possible if the cache overhead (dictionary operations + validation probes) exceeds the probe savings. Most likely with very small generators (fewer than 5 coordinates).

**Instrumentation: materializations and property invocations.** The reducer already logs `property_invocations` in the `property_passed` event. Add a `materializations` counter alongside it — every call to `ReductionMaterializer.materialize()` or `SequenceDecoder.decode*()` increments this counter, regardless of whether the property is subsequently invoked (rejected candidates are materialized but not evaluated). Log both in `bonsai_cycle_end`:

```swift
ExhaustLog.debug(
    category: .reducer,
    event: "bonsai_cycle_end",
    metadata: [
        // ... existing fields ...
        "materializations": "\(cycleMaterializations)",
        "property_invocations": "\(cyclePropertyInvocations)",
        "warm_start_hits": "\(warmStartHits)",
        "warm_start_restarts": "\(warmStartRestarts)",
        "cold_starts": "\(coldStarts)",
    ]
)
```

These are distinct metrics. Not every materialization leads to a property invocation — the materializer may reject the candidate internally (out-of-range values, structural mismatches), and the reject cache filters probes before materialization even begins. The ratio `property_invocations / materializations` measures materialization efficiency. The stall cache should reduce `materializations` (fewer probes emitted by the encoder). `property_invocations` drops only to the extent that fewer materializations produce fewer valid candidates to evaluate — the relationship depends on the materialization success rate, which is independent of the cache.

**Measurement method:** Run the existing test suite twice — once with the cache enabled, once disabled (pass `nil` for `warmStarts`). Compare per-test:
- Total `materializations` across all cycles.
- Total `property_invocations` across all cycles.
- Per-cycle breakdown of `warm_start_hits`, `warm_start_restarts`, `cold_starts`.
- Shrink output (must be identical).

### Phase 2 (Lift Report)
- Unit test: run `ReductionMaterializer.materialize()` in guided mode with a known prefix and fallback tree. Verify the lift report classifies each coordinate correctly.
- Unit test: verify `fidelity` computation (all tier 1 → 1.0, all tier 3 → 0.0, mixed → correct ratio).

---

## Key Files

| File | Role |
|------|------|
| `ReductionState.swift` | Owns the stall cache; clears on structural acceptance |
| `SequenceEncoder.swift` | `AdaptiveEncoder` protocol — `warmStarts` parameter on `start()`, `stallRecords` property, convenience overload |
| `BinarySearchToSemanticSimplestEncoder.swift` | Use warm starts at stepper construction; record stalls at convergence |
| `BinarySearchToRangeMinimumEncoder.swift` | Same |
| `ReductionState+Bonsai.swift` | Build warm starts from cache; harvest stall records after encoder runs |
| `ReduceFloatEncoder.swift` | Warm start for stage-skip (bit-pattern change detection); Phase 0 instrumentation |
| `ReductionMaterializer.swift` | Populate lift report in `handleChooseBits` |
| `SequenceDecoder.swift` | Propagate lift report through decode path |
| `BonsaiScheduler.swift` | Phase 0 instrumentation logging |
