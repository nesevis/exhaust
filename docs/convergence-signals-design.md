# Convergence Signals: Typed Encoder Feedback for Cross-Cycle Factory Decisions

## Problem

The convergence cache (`[Int: ConvergedOrigin]`) carries warm-start data across cycles — where to resume binary search. But it does not carry *what happened* at convergence. The factory emits the same encoder on every cycle regardless of the prior cycle's outcome. When an encoder observes something actionable (non-monotone failure surface, zeroing dependency, fibre bail), that observation is lost.

The proposed `sawUnexpectedResult: Bool` flag on the binary search stepper collapses distinct observations into a single bit. A non-monotone gap (property passed between two known failures) and a non-monotone island (property failed where monotonicity predicted passing) have different implications for recovery. A boolean flag loses the distinction and the data the factory needs to select the correct response.

## Design

### Per-coordinate signals: `ConvergenceSignal`

Each encoder produces a typed signal when it terminates. The signal records what the encoder *observed*, not what it *did*. The factory reads the signal and selects the next encoder accordingly.

```swift
enum ConvergenceSignal: Hashable, Sendable {
    /// Binary search converged normally. Monotonicity held throughout.
    case monotoneConvergence

    /// Binary search: the property passed at a value where the monotonicity
    /// assumption predicted failure. The failure surface has a gap — bounded
    /// scan below the convergence point may find a lower floor.
    /// - `remainingRange`: number of values below the convergence bound.
    ///   The factory uses this to decide scan vs accept.
    case nonMonotoneGap(remainingRange: Int)

    /// Zero-value: all-at-once zeroing failed but individual zeroing
    /// succeeded. The coordinate has dependencies on other coordinates —
    /// zeroing it alone breaks an invariant that holds when neighboring
    /// coordinates are also zeroed.
    case zeroingDependency
}
```

### Non-monotonicity detection

The binary search stepper maintains a narrowing range: a lower bound (last pass or range minimum) and an upper bound (last failure or range maximum). Non-monotonicity is detected during the normal narrowing process — no additional probes are needed.

**For `.rangeMinimum` (searching downward):** monotonicity predicts that if the property fails at value w, it fails at all values v < w. The stepper probes a midpoint v between the lower bound and upper bound. If the property passes at v while there exists a known failure at w > v, the monotonicity assumption is violated. The pass at v is the detection event — the stepper has a failure above (w) and a pass below (v), which contradicts "all values below a failure also fail."

**For `.semanticSimplest` (searching upward toward simplest):** monotonicity predicts that if the property fails at a value far from semantic simplest, it fails at all values further from semantic simplest. A pass at v while there exists a known failure at a value further from semantic simplest than v is the detection event.

In both cases, the stepper observes the contradiction during its normal binary search narrowing — it probes a midpoint, gets a pass, and narrows the range. The detection requires no extra state beyond what the stepper already maintains (current lower and upper bounds). The stepper records `.nonMonotoneGap(remainingRange:)` at termination with `remainingRange` computed as the number of values between the range lower bound and the convergence point.

Note: detection does not require failures on both sides of a pass. It requires a failure on one side (the side the search started from) and a pass on the other (the midpoint that narrowed the range). The stepper has not probed below the pass — it cannot know whether a failure exists there. The signal is "monotonicity was violated, there *may* be a lower floor" — not "there *is* a lower floor."

### Updated `ConvergedOrigin`

```swift
struct ConvergedOrigin: Sendable {
    /// The bit-pattern value at which the search converged. Warm-start data.
    let bound: UInt64

    /// What the encoder observed at convergence. Factory decision data.
    let signal: ConvergenceSignal

    /// Which encoder configuration produced this entry. Staleness discriminant.
    let configuration: EncoderConfiguration

    /// The cycle in which this observation was recorded. Staleness detection.
    let cycle: Int
}

/// Identifies the encoder configuration that produced a convergence record.
///
/// The factory uses this to reject cache entries from a different configuration.
/// When the factory switches from `.semanticSimplest` to `.rangeMinimum` for the
/// same position between cycles, the cached bound from the upward search is not
/// meaningful as a downward starting point. The configuration discriminant catches
/// this — the factory checks `cache[position]?.configuration == currentConfig`
/// before consuming the warm-start bound.
enum EncoderConfiguration: Hashable, Sendable {
    case binarySearchRangeMinimum
    case binarySearchSemanticSimplest
    case linearScan
    case zeroValue
}
```

**Note on `EncoderConfiguration` granularity.** The enum conflates encoder identity with configuration — `.binarySearchRangeMinimum` and `.binarySearchSemanticSimplest` are configurations of the same encoder type, while `.linearScan` and `.zeroValue` are different encoder types with no configuration variants. This flat enum works for the current four cases. If encoder types gain more configurations (for example, `LinearScanEncoder` with `.upward` vs `.fromSimplest`), the enum grows multiplicatively. A `(EncoderName, configurationHash)` pair would be more general but adds complexity. The flat enum is a deliberate simplification for the initial scope — restructure if more than six to eight cases emerge.

**`bound`** is warm-start data — where to resume. The emitted encoder reads it from `context.convergedOrigins` to narrow the search range on the next cycle. Same role as today.

**`signal`** is the observation — what happened. The factory reads it to decide which encoder to emit. New.

**`configuration`** is the staleness discriminant — which encoder produced this entry. Replaces the current `direction: Direction` field. The convergence cache persists across cycles, and the factory can emit a different configuration for the same position on different cycles. Example: cycle 1 emits `BinarySearchEncoder(.semanticSimplest)`, which converges at bound 42 searching upward. Cycle 2, after a structural change, the factory emits `BinarySearchEncoder(.rangeMinimum)` for the same position. The cache still holds bound 42 from the upward search. Without a discriminant, the new encoder warm-starts from 42 — the bound was found by a different search strategy and may not be meaningful as a downward starting point. The `configuration` field catches this: the factory checks `cache[position]?.configuration == .binarySearchRangeMinimum` before consuming the bound. Mismatched entries are discarded, same as the current `direction` check but generalized to all encoder types.

**`cycle`** is when it happened. The factory or verification sweep uses it for staleness detection. New — replaces the ad hoc "was this entry from the current cycle?" checks in the verification sweep.

**`direction` is removed.** Direction was a proxy for configuration match. The `configuration` discriminant subsumes it — it distinguishes `.binarySearchRangeMinimum` from `.binarySearchSemanticSimplest` (which is what the `direction` check was actually doing) and extends to new encoder types (`linearScan`, `zeroValue`) that the `Direction` enum cannot represent.

### Per-edge signals: `EdgeObservation`

Per-fibre observations from the downstream role in a composition do not belong in the per-coordinate convergence cache. They describe what the downstream encoder observed about the entire fibre, not about any single coordinate. Attaching them to every coordinate in the range is redundant; attaching to one arbitrary coordinate is fragile.

These belong on the reduction state, keyed by region index:

```swift
struct EdgeObservation: Sendable {
    /// What the downstream encoder observed about the fibre.
    let signal: FibreSignal

    /// The upstream value that produced this fibre.
    let upstreamValue: UInt64

    /// The cycle in which this observation was recorded.
    let cycle: Int
}

enum FibreSignal: Hashable, Sendable {
    /// Exhaustive or pairwise search covered the full fibre. No failure found.
    /// The fibre is clean at this upstream value.
    case exhaustedClean

    /// Exhaustive or pairwise search covered the full fibre. Failure found.
    /// Floor is exact for the downstream coordinates.
    case exhaustedWithFailure

    /// The downstream encoder bailed before completing coverage.
    /// The fibre was too large for the budget or the selected mode.
    /// - `paramCount`: number of value positions in the fibre.
    case bail(paramCount: Int)
}
```

Storage is per-edge on the reduction state, not on the CDG (which is immutable structural data):

```swift
edgeObservations: [Int: EdgeObservation]  // keyed by region index
```

**Observation timing.** The composition iterates over upstream candidates (downward from the current value). The downstream runs once per upstream candidate that passes the lift. The observation records the result from the **last upstream candidate attempted**, regardless of outcome. The `upstreamValue` field tells the factory which upstream value the observation is about. If the composition tried upstream values 8, 5, 3 and the downstream bailed at 5 but succeeded at 3, the observation records the success at 3. If the composition bailed at 3 and never tried 2, the observation records the bail at 3 — next cycle, the factory sees the bail and knows it was at upstream value 3, not at the current value (which may have been reduced further by Phase 2).

**Invalidation after structural changes.** Phase 1 structural deletions can change the CDG — deleting a bind region shifts region indices for subsequent regions. Edge observations keyed by the old region index would refer to the wrong edge. Invalidation rule: clear all edge observations after any structural acceptance in Phase 1. This is conservative (some observations might still be valid) but safe and simple. The convergence cache already uses full invalidation on structural change (`invalidateAll()`). The edge observations follow the same policy. Precise invalidation (only edges in the affected subtree) is a future refinement using `BindSpanIndex` scope tracking.

### Two caches, two scopes

```swift
// Per-coordinate: warm-start and recovery for value encoders.
convergenceCache: [Int: ConvergedOrigin]

// Per-edge: downstream observations for composition decisions.
edgeObservations: [Int: EdgeObservation]
```

The factory consults both. For a standalone coordinate, it reads the convergence cache and pattern-matches on the signal. For a composition edge, it reads the edge observation and selects the downstream (or decides to skip the edge). The two decision paths are independent factory outputs.

## Factory consumption

The factory pattern-matches on signals to select encoders. Each signal carries the data the recovery decision needs — no recomputation required.

### Per-coordinate decisions

```swift
switch cache[position]?.signal {
case .nonMonotoneGap(let remaining) where remaining <= 64:
    // Small gap — bounded linear scan below the convergence point.
    emit LinearScanEncoder(upperBound: cache[position]!.bound - 1)

case .nonMonotoneGap:
    // Gap too large to scan — accept non-minimal floor, log diagnostic.
    // Re-emit binary search; it will converge at the same (non-minimal) floor.
    emit BinarySearchEncoder(configuration: config)

case .zeroingDependency:
    // Suppress zero-value for this coordinate. Emit binary search instead —
    // it continues toward the floor without the all-at-once zeroing attempt.
    // Redistribution encoders (RedistributeByTandemReduction, RelaxRound)
    // operate on this coordinate through their normal pair/group selection —
    // no factory intervention needed for coupled-coordinate reduction.
    emit BinarySearchEncoder(configuration: config)

case .scanComplete:
    // Linear scan completed. Revert to binary search.
    // The bound is the lowest known floor — either the scan's finding or the
    // original convergence point if no lower floor was found.
    // Lifecycle: monotoneConvergence → (stable) or
    //   nonMonotoneGap → linearScan → scanComplete → binarySearch →
    //     monotoneConvergence (common) or nonMonotoneGap again (coupled surfaces)
    emit BinarySearchEncoder(configuration: config)

case .monotoneConvergence, nil:
    // Normal path.
    emit BinarySearchEncoder(configuration: config)
}
```

### Per-edge decisions

```swift
switch edgeObservations[edge.regionIndex] {
case .some(let obs) where obs.signal == .exhaustedClean
    && obs.upstreamValue == currentUpstreamValue
    && edge.isStructurallyConstant:
    // Fibre was fully searched at this upstream value and was clean.
    // For structurally constant edges, same upstream value = same fibre
    // structure, so the observation is valid. Skip the composition.
    skip edge

case .some(let obs) where obs.signal == .exhaustedClean
    && obs.upstreamValue == currentUpstreamValue:
    // Data-dependent edge: same upstream value, but downstream coordinates
    // may have been modified by Phase 2 standalone encoders between cycles.
    // The fibre structure depends on the upstream value but the property's
    // behavior within the fibre depends on downstream state too.
    // Do NOT skip — the observation may be stale.
    emit composition with standard budget

case .some(let obs) where obs.signal == .bail:
    // Downstream bailed. DownstreamPick should handle this via
    // ZeroValue alternative, but if it persists, consider reducing budget
    // to avoid wasting lifts.
    emit composition with reduced budget

case .some, nil:
    // Normal path.
    emit composition with standard budget
}
```

The `exhaustedClean` skip is only safe for structurally constant edges. For data-dependent edges, the fibre structure is determined by the upstream value, but the property's behavior within the fibre depends on all coordinates — including downstream coordinates that Phase 2 may have modified between cycles. Same upstream value does not guarantee same property behavior. A fibre fingerprint that includes downstream state would enable safe skipping for data-dependent edges, but the cost of computing the fingerprint (requires a lift) may exceed the cost of just running the composition.

## `LinearScanEncoder`

A bounded exhaustive scan of a value range. Produced by the factory when `ConvergenceSignal.nonMonotoneGap` has a `remainingRange` within the scan threshold (≤ 64).

### Phase placement

The `LinearScanEncoder` runs in **Phase 2 (fibre descent)**, not in the exploration leg. Binary search runs in Phase 2. The linear scan is the factory's replacement for binary search on coordinates where non-monotonicity was detected — it occupies the same slot in the Phase 2 descriptor chain, not a separate slot in a different phase.

If the scan ran in the exploration leg, there would be a full Phase 2 cycle between the binary search that detected the gap and the scan that recovers it. That Phase 2 cycle would re-run binary search on the same coordinate, converge at the same non-minimal floor, and overwrite the `.nonMonotoneGap` signal with `.monotoneConvergence` — the factory would never see the gap signal.

The factory's per-coordinate decision emits the `LinearScanEncoder` descriptor *in place of* the `BinarySearchEncoder` descriptor for that coordinate in the Phase 2 descriptor chain. The descriptor chain mechanism is the same — only the encoder in the descriptor changes. The factory reads `cache[position]?.signal`, and when it sees `.nonMonotoneGap(remaining) where remaining <= 64`, it emits a `LinearScanEncoder` descriptor instead of a `BinarySearchEncoder` descriptor for that position.

### Scan direction

For `.rangeMinimum` recovery: scan **upward** from `rangeLowerBound` to `convergenceBound - 1`. The first failure found is a lower floor than the binary search convergence point — the scan can stop early. Worst case: `remainingRange` probes (no failure exists below the convergence point, confirming the binary search was correct despite the non-monotonicity). Best case: one probe (failure at the range minimum).

For `.semanticSimplest` recovery: scan **from semantic simplest outward** through the remaining range. Same early-stop logic.

The scan direction is determined by the factory based on the same configuration it used for the binary search that produced the `.nonMonotoneGap`. The `LinearScanEncoder` receives the direction as a configuration parameter.

### Termination signal

The scan produces a `ConvergenceSignal` when it terminates:

```swift
case scanComplete(foundLowerFloor: Bool)
```

- `.scanComplete(foundLowerFloor: true)`: the scan found a failure below the binary search convergence point. The bound on the new `ConvergedOrigin` is the lowest failure found. Next cycle, the factory can revert to `BinarySearchEncoder` — the non-monotonicity has been resolved (the true floor is now known, or at least a lower one).
- `.scanComplete(foundLowerFloor: false)`: the scan exhausted the remaining range without finding a lower failure. The binary search convergence point was the true floor despite the non-monotonicity. Next cycle, the factory emits `BinarySearchEncoder` with the same bound — no further scanning needed.

In both cases, the factory reverts to `BinarySearchEncoder` on the next cycle. The scan is typically a one-cycle intervention. However, if other encoders change neighboring coordinates between cycles (redistribution, structural deletion, composition acceptances), the failure surface along the scanned coordinate may shift. The reverted binary search may then encounter non-monotonicity again and emit another `.nonMonotoneGap`, triggering another scan. This scan-revert-scan loop converges because each scan finds the true floor given the current state of other coordinates, and other coordinates are also converging. The loop can repeat on highly coupled failure surfaces — the implementation must not assume scan happens at most once per coordinate.

### Interface

```swift
struct LinearScanEncoder: ComposableEncoder {
    let name: EncoderName = .linearScan
    let phase: ReductionPhase = .fibreDescent

    /// The range to scan, derived from the convergence bound and range lower bound.
    let scanRange: ClosedRange<UInt64>

    /// The direction to scan (upward from lower bound, or from semantic simplest outward).
    let scanDirection: ScanDirection

    enum ScanDirection {
        case upward
        case fromSimplest
    }
}
```

## Profiling

The signal type structure gives profiling typed data for free. Instead of counting "unexpected results" (a boolean), the report decomposes by signal:

- **Per-coordinate signal distribution**: count of `.monotoneConvergence`, `.nonMonotoneGap` (with remaining range histogram), `.zeroingDependency`, `.scanComplete` occurrences per cycle.
- **Per-edge signal distribution**: count of `.exhaustedClean`, `.exhaustedWithFailure`, `.bail` (with parameter count histogram) per cycle.
- **Recovery success rate**: for each signal that triggers a non-default encoder, what fraction of those recovery encoders found an improvement? This measures whether the signal is actionable.

These decompose the existing `predict=X/Y` metric into per-scope, per-signal metrics with distinct improvement paths.

## Migration path

### Phase 1: `ConvergenceSignal` on `ConvergedOrigin`

1. Add `ConvergenceSignal` and `EncoderConfiguration` enums.
2. Add `signal`, `configuration`, and `cycle` fields to `ConvergedOrigin`. Default `signal` to `.monotoneConvergence` for backward compatibility.
3. Replace `direction: Direction` with `configuration: EncoderConfiguration`. Update `BinarySearchEncoder` to write `.binarySearchRangeMinimum` or `.binarySearchSemanticSimplest` and to check `cache[position]?.configuration` instead of `cache[position]?.direction` for warm-start validation.
4. Add `LinearScanEncoder` — bounded exhaustive scan of a value range with configurable direction.
5. Update `BinarySearchEncoder` to detect non-monotonicity during the stepper's narrowing process and produce `.nonMonotoneGap(remainingRange:)` at termination. Detection condition: the property passed at a value where the monotonicity assumption predicted failure (a pass within the narrowing range while a failure exists on the other side).
6. Update `ZeroValueEncoder` to produce `.zeroingDependency` when batch zeroing fails but individual zeroing succeeds.
7. Factory reads signals — emit `LinearScanEncoder` for small `.nonMonotoneGap`, suppress `ZeroValueEncoder` and emit `BinarySearchEncoder` for `.zeroingDependency`.

### Phase 2: `EdgeObservation` on reduction state

1. Add `FibreSignal` and `EdgeObservation` types.
2. Add `edgeObservations: [Int: EdgeObservation]` to `ReductionState`.
3. Update `runKleisliExploration` to write observations from the last upstream candidate attempted for each composition edge.
4. Add invalidation: clear all edge observations after structural acceptance in Phase 1.
5. Factory reads observations — skip structurally constant edges with `.exhaustedClean` at the same upstream value.

### Phase 3: Profiling

1. Add per-signal counters to `ReductionStats` (`nonMonotoneGapCount`, `zeroingDependencyCount`, `scanCompleteCount`, `fibreExhaustedCleanCount`, `fibreBailCount`).
2. Wire through `ExhaustReport`.
3. Update `profilingSummary` format.

## Non-goals

- **Encoder-to-encoder communication.** Signals flow from encoders to the factory via the cache, not between encoders directly. The factory is the sole consumer and decision-maker.
- **Signal-based scheduling.** The factory uses signals for encoder *selection*, not for budget allocation or ordering. Budget and ordering remain based on structural signals (leverage, domain ratio).
- **Exhaustive signal vocabulary.** The initial vocabulary covers the observations that have known recovery paths. New signals are added when a new encoder observes something actionable. The enum is extensible.
- **Data-dependent edge skipping.** The `exhaustedClean` skip is restricted to structurally constant edges. A fibre fingerprint for data-dependent edges is a future optimization — the cost of computing it (requires a lift) likely exceeds the savings from skipping.
