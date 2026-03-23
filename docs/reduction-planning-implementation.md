# Implementation Plan: Reduction Planning Correctness Fixes

Two standalone correctness fixes from `docs/reduction-planning.md`. Both detect and recover from stale convergence cache entries that cause the reducer to converge at non-minimal values.

## Status: Complete

Both fixes implemented and tested. 56 shrinking tests pass. Overhead: 1 extra property invocation on one test case (Bound5 Pathological 3). No counterexample quality regressions.

## Fix 1: Warm-start validation in KleisliComposition (complete)

### Problem

The `KleisliComposition` transfers convergence records between adjacent upstream values, gated by lift report coverage. A stale floor that still fails the property looks valid — the downstream encoder converges to a non-minimal value.

### Implementation

The validation lives in `runKleisliExploration` (the driver), not in the composition — the composition does not have access to `dec` (the property check). The composition exposes transfer state; the driver validates it.

**KleisliComposition changes** (`KleisliComposition.swift`):
- Added `pendingTransferOrigins: [Int: ConvergedOrigin]?` — raw convergence records from the previous downstream, populated when downstream exhausts.
- Added `previousUpstreamBitPattern: UInt64?` and computed `upstreamDelta: UInt64?` — tracks upstream value movement in bit-pattern space for delta computation.
- Added `setValidatedOrigins(_:)` — called by the driver after `floor - 1` validation. The downstream initialization uses validated origins (or nil for cold-start).
- Removed `convergenceTransferOrigins(from:)` — the internal coverage-threshold transfer replaced by driver-side validation.
- Validated origins are consumed on use (set to nil after downstream initialization).

**runKleisliExploration changes** (`ReductionState+Bonsai.swift`):
- Between upstream probes: reads `pendingTransferOrigins` and `upstreamDelta`.
- Delta > 1 or first probe or exhaustive downstream: `setValidatedOrigins(nil)` (cold-start).
- Delta == 1: validates each origin at `floor - 1` via decoder. On first stale detection (property fails at `floor - 1`): discards all, accepts the improved result, cold-starts.
- Validation probes charged to `legBudget`.

### Edge cases handled

- `floor == rangeLowerBound`: skip validation (trivially valid).
- Upstream delta > 1: cold-start immediately (binary search jumps are almost always > 1; transfer only applies to final unit-step probes near convergence).
- First upstream probe: cold-start (no previous value).
- Exhaustive downstream (`FibreCoveringEncoder`): cold-start (exhaustive doesn't use convergence transfer).

## Fix 2: Post-termination verification sweep (complete)

### Problem

The reducer converges toward cached floors by design. If the cache is stale, the counterexample is at the cached floors — indistinguishable from the correct case during reduction.

### Implementation

After the main `while stallBudget > 0` loop in `BonsaiScheduler.run()`:

**`detectStaleness`** (`BonsaiScheduler.swift`): walks all value positions. For each with a cached floor above `rangeLowerBound`, probes `floor - 1` via `SequenceDecoder.exact()`. Returns on first stale detection. Accepts the result if it `shortLexPrecedes` the current sequence.

**`computeVerificationBudget`** (`BonsaiScheduler.swift`): `.fast` (maxStalls ≤ 1) caps at `fibreDescentBudget` (975, best-effort). `.slow` uses `sum(bitsNeeded per coordinate)` via bit-width computation (no floating-point).

**Post-termination sweep**: if staleness detected, saves the convergence cache, clears it, runs one `runFibreDescent` cycle without cache, restores the cache. If Phase 2 found improvements, re-enters the main loop with reset stall counter (once only — `verificationSweepCompleted` flag prevents a second re-entry). Second staleness detection after re-entry logs a `systematic_cache_staleness` diagnostic and terminates.

### Files changed

| File | Fix | Changes |
|------|-----|---------|
| `KleisliComposition.swift` | 1 | Added `pendingTransferOrigins`, `previousUpstreamBitPattern`, `upstreamDelta`, `setValidatedOrigins(_:)`. Removed `convergenceTransferOrigins(from:)`, `downstreamConvergenceTransfer`. Downstream initialization uses validated origins. |
| `ReductionState+Bonsai.swift` | 1 | Added validation loop in `runKleisliExploration` between upstream probes. |
| `BonsaiScheduler.swift` | 2 | Added `detectStaleness`, `computeVerificationBudget`, post-termination sweep with re-entry guard after main loop. |
| `Bound5.swift` | 2 | Updated expected `propertyInvocations` from 410 to 411 (+1 from verification sweep probe). |

### Verification results

- Coupling challenge: finds `[1, 0]`, 163 invocations (unchanged).
- All 56 shrinking tests pass.
- Bound5 Pathological 3: +1 property invocation (verification sweep probes one coordinate, finds it valid).
- No counterexample quality regressions on any test case.
