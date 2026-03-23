# Implementation Plan: Reduction Planning Correctness Fixes

Two standalone correctness fixes from `docs/reduction-planning.md`. Both are independent of profiling and improve the reducer now.

## Fix 1: Warm-start validation in KleisliComposition

### Problem

The `KleisliComposition` transfers convergence records between adjacent upstream values, gated by lift report coverage. A stale floor that still fails the property looks valid — the downstream encoder converges to a non-minimal value (premature convergence).

### Fix

Inside `KleisliComposition`, after computing the convergence transfer origins but before initializing the downstream encoder: validate each transferred floor by probing at `floor - 1`. If the property fails at `floor - 1`, the floor is stale — discard all transferred convergence points and cold-start the downstream.

### Architecture: validation in the driver, not the composition

The `KleisliComposition` does not have access to `dec` (the property check). Composition composes `enc` halves only — the property check happens at the composition boundary. The validation probe requires a property check, so it cannot live inside the composition.

The validation lives in `runKleisliExploration` (the driver loop), which has access to the property, the decoder, and the sequence. The composition exposes what it would transfer; the driver validates it; the composition receives only validated transfers.

**KleisliComposition changes:**
- Add `pendingTransferOrigins: [Int: ConvergedOrigin]?` — the raw convergence records from the previous upstream iteration's downstream, unvalidated. Populated after each upstream probe's downstream exhausts.
- Add `func setValidatedOrigins(_ origins: [Int: ConvergedOrigin]?)` — called by the driver after validation. The composition uses these (not the raw pending origins) when initializing the downstream.
- Add `previousUpstreamBitPattern: UInt64?` — tracks the previous upstream value for delta computation.
- Remove the internal `convergenceTransferOrigins(from:)` method — the driver handles this now.

**runKleisliExploration changes:**
Between each upstream probe, after the composition exposes `pendingTransferOrigins`:

```
let pending = composed.pendingTransferOrigins
let delta = composed.upstreamDelta  // |current - previous| in user-value space

if delta > 1 || pending == nil || isExhaustiveDownstream {
    // Cold-start: no transfer
    composed.setValidatedOrigins(nil)
else:
    // Validate each pending origin at floor - 1
    var validated = pending!
    for (index, origin) in pending! {
        guard origin.bound > rangeLowerBound(at: index) else { continue }

        let probeBP = origin.bound - 1
        var candidate = state.sequence
        candidate[index] = .value(.init(
            choice: ChoiceValue(tag.makeConvertible(bitPattern64: probeBP), tag: tag),
            validRange: ..., isRangeExplicit: ...
        ))
        legBudget.recordMaterialization()

        if let result = try decoder.decode(
            candidate: candidate, gen: gen, tree: tree,
            originalSequence: sequence, property: property
        ), result.sequence.shortLexPrecedes(sequence) {
            // Property fails at floor - 1: floor is stale
            // Discard ALL pending origins and cold-start
            composed.setValidatedOrigins(nil)
            break
        }
        // Property passes at floor - 1: this origin is valid, keep it
    }
    // If no staleness detected, pass validated origins
    composed.setValidatedOrigins(validated)
```

### Edge cases

- **floor == rangeLowerBound**: skip validation for that origin. Nothing below it.
- **upstream delta > 1**: skip validation entirely, cold-start immediately. Binary search jumps (8 → 4) are delta > 1 in user-value space. Transfer only applies to the final unit-step probes near convergence.
- **First upstream probe (no previous)**: always cold-start.
- **Exhaustive downstream**: skip validation. Exhaustive enumeration does not use convergence transfer.

### Budget accounting

Each validation probe is one property invocation + one materialization, charged to `legBudget` in `runKleisliExploration`. For a transfer with `t` points, worst case is `t` probes before finding staleness. Typical case: first stale floor found early, all discarded — 1–3 probes.

### Upstream delta computation

The upstream encoder proposes values via binary search, which halves toward the target. Adjacent probes are NOT adjacent values (binary search jumps from 8 to 4, not 8 to 7). The delta is almost always > 1. Convergence transfer is only used in the final 1–2 upstream probes — the ones closest to the target where binary search makes unit steps.

Transfer when the upstream moved by exactly 1 step in user-value space (not bit-pattern space). For signed integers: `|currentValue - previousValue| == 1` after zigzag decoding. `KleisliComposition` exposes `upstreamDelta: UInt64?` computed from `previousUpstreamBitPattern` and the current upstream probe's bit pattern, decoded to user-value space.

### Files changed

| File | Change |
|------|--------|
| `Sources/ExhaustCore/Interpreters/Reduction/KleisliComposition.swift` | Add `pendingTransferOrigins`, `setValidatedOrigins(_:)`, `previousUpstreamBitPattern`, `upstreamDelta`. Remove `convergenceTransferOrigins(from:)`. The composition proposes transfers; the driver validates them. |
| `Sources/ExhaustCore/Interpreters/Reduction/ReductionState+Bonsai.swift` | In `runKleisliExploration`, after each upstream probe: read `pendingTransferOrigins` and `upstreamDelta`, validate at `floor - 1`, call `setValidatedOrigins`. |

### Verification

1. Test with the coupling challenge — should still find `[1, 0]` (warm-start validation doesn't prevent correct convergence transfer, only stale transfer).
2. Test with a generator where the bind-inner controls a range and downstream values are at the range boundary — the validation should detect staleness and cold-restart.
3. `swift test --filter "Shrinking"` — all 56 tests pass, no regressions.
4. No test should produce a larger counterexample than before (quality guarantee).

---

## Fix 2: Post-termination verification sweep

### Problem

The reducer converges toward cached floors by design. If the cache is stale (floor higher than the true floor), the counterexample is at the cached floors — indistinguishable from the correct case during reduction. No in-cycle gate detects this.

### Fix

After the main reduction loop in `BonsaiScheduler.run()` terminates, probe `floor - 1` for each value coordinate. If any floor is stale (property fails at `floor - 1`), run one Phase-2-only cycle with all gates disabled and `convergedOrigins: nil`.

### Where

`Sources/ExhaustCore/Interpreters/Reduction/BonsaiScheduler.swift`, after the `while stallBudget > 0` loop exits and before the return statement.

### Logic

```
// Post-termination verification sweep
let staleness = detectStaleness(state)
if staleness.hasStaleFloors {
    // Run one Phase-2-only cycle with gates disabled
    var verificationBudget = computeVerificationBudget(state, config)
    _ = try state.runFibreDescent(
        budget: &verificationBudget,
        dag: state.rebuildDAGIfNeeded(),
        convergedOrigins: nil,  // no cache — search from scratch
        gatesDisabled: true
    )

    // Re-entry: if Phase 2 found improvements, the stall was false
    if state.bestSequence.shortLexPrecedes(preVerificationBest) {
        // Reset stall counter, re-enter main loop — but only once
        if verificationSweepCompleted == false {
            verificationSweepCompleted = true
            stallBudget = config.maxStalls
            continue  // re-enter the main while loop
        }
        // Second staleness after re-entry: log diagnostic, terminate
        ExhaustLog.debug(category: .reducer, event: "systematic_cache_staleness")
    }
}
```

### Staleness detection

```swift
struct StalenessCheck {
    let hasStaleFloors: Bool
    let probesUsed: Int
}

func detectStaleness(_ state: ReductionState) -> StalenessCheck {
    var probesUsed = 0
    for index in 0 ..< state.sequence.count {
        guard let value = state.sequence[index].value,
              let origin = state.convergenceCache.convergedOrigin(at: index),
              let range = value.validRange
        else { continue }

        // Skip trivially valid floors (at range minimum)
        let floorBP = origin.bound
        guard floorBP > range.lowerBound else { continue }

        // Probe at floor - 1
        let probeBP = floorBP - 1
        var candidate = state.sequence
        candidate[index] = .value(.init(
            choice: ChoiceValue(value.choice.tag.makeConvertible(bitPattern64: probeBP), tag: value.choice.tag),
            validRange: value.validRange,
            isRangeExplicit: value.isRangeExplicit
        ))

        probesUsed += 1
        // Materialize and check property
        if let result = try? SequenceDecoder.exact().decode(
            candidate: candidate,
            gen: state.gen,
            tree: state.tree,
            originalSequence: state.sequence,
            property: state.property
        ) {
            if result.sequence.shortLexPrecedes(state.sequence) {
                // Property fails at floor - 1: cache is stale
                state.accept(result, structureChanged: false)
                return StalenessCheck(hasStaleFloors: true, probesUsed: probesUsed)
            }
        }
    }
    return StalenessCheck(hasStaleFloors: false, probesUsed: probesUsed)
}
```

### Verification budget

```swift
func computeVerificationBudget(_ state: ReductionState, _ config: BonsaiReducerConfiguration) -> Int {
    switch config {
    case _ where config.maxStalls <= 1:
        // .fast: cap at standard Phase-2 budget (best-effort)
        return BonsaiScheduler.fibreDescentBudget
    default:
        // .slow: expanded budget based on actual coordinate ranges
        var budget = 0
        for index in 0 ..< state.sequence.count {
            guard let value = state.sequence[index].value,
                  let range = value.validRange
            else { continue }
            let rangeSize = range.upperBound - range.lowerBound + 1
            budget += Int(ceil(log2(Double(max(2, rangeSize)))))
        }
        return budget
    }
}
```

### Passing `gatesDisabled` and `convergedOrigins: nil` to `runFibreDescent`

The current `runFibreDescent` reads `convergenceCache.allEntries` internally. For the verification cycle, it must NOT use the cache. Two options:

**Option A**: Add parameters to `runFibreDescent`:
```swift
func runFibreDescent(
    budget: inout Int,
    dag: ChoiceDependencyGraph?,
    overrideConvergedOrigins: [Int: ConvergedOrigin]?? = nil  // nil = use cache, .some(nil) = no cache
) throws -> Bool
```

**Option B**: Temporarily clear the convergence cache before the verification cycle and restore after:
```swift
let savedCache = state.convergenceCache
state.convergenceCache = ConvergenceCache()
_ = try state.runFibreDescent(budget: &verificationBudget, dag: dag)
state.convergenceCache = savedCache
```

Option B is simpler — no API change to `runFibreDescent`. The cache is a value type, so save/restore is a copy.

### Re-entry guard

A `verificationSweepCompleted: Bool` on the scheduler (local to `run()`). Set after the first re-entry. If the second termination detects staleness and the flag is set, log a diagnostic and terminate without sweeping.

### Files changed

| File | Change |
|------|--------|
| `Sources/ExhaustCore/Interpreters/Reduction/BonsaiScheduler.swift` | Add post-termination sweep after the main loop. `detectStaleness` function. `computeVerificationBudget` function. `verificationSweepCompleted` flag. Re-entry logic. |

### Verification

1. Test with a generator where Phase 1c reduces a bind-inner value, changing downstream ranges, and the convergence cache has stale entries for the downstream — the sweep should detect staleness and the re-entered cycle should find a smaller counterexample.
2. Test with generators that already produce minimal counterexamples — the sweep should detect no staleness (zero cost).
3. `swift test --filter "Shrinking"` — all tests pass.
4. Check that `.fast` budget caps the verification cycle at 975 probes.
5. Check that the re-entry guard prevents infinite loops — a second staleness detection logs the diagnostic and terminates.

---

## Implementation order

1. **Warm-start validation** (Fix 1) — smaller change, contained within KleisliComposition. Establishes the `floor - 1` validation pattern.
2. **Post-termination sweep** (Fix 2) — uses the same `floor - 1` pattern but at the scheduler level. Builds on the pattern from Fix 1.

Both fixes are independent — either can be implemented alone. But Fix 1 first establishes the validation logic that Fix 2 reuses conceptually.

## Success criteria

- No test case produces a larger counterexample than before.
- No test case uses more than 5% additional property invocations (the validation probes are overhead).
- The coupling challenge still finds `[1, 0]`.
- All 56 shrinking tests pass.
