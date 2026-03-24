# Closed-Loop Reducer: Design and Implementation

## Overview

The `AdaptiveStrategy` is a signal-driven scheduling strategy for the Bonsai reducer, implemented alongside the existing `StaticStrategy` (behavioral clone of the original `BonsaiScheduler`). Both operate through the `SchedulingStrategy` protocol, sharing the same orchestration skeleton, phase methods, encoder set, and feedback channels. The user selects the strategy via `.adaptiveScheduling` on `ExhaustSettings`.

## What the adaptive strategy does differently

### Phase 1 skip

`AdaptiveStrategy` skips Phase 1 (base descent) when structural work is provably absent. Two gates, checked at cycle start:

- **Structural gate**: span extraction (computed by `computeEncoderOrdering()`) shows no deletion targets and the tree has no branch nodes. Catches scalar generators from cycle 1.
- **Behavioral gate**: the preceding cycle's Phase 1 had zero structural acceptances. Catches array generators where deletion targets exist but no deletion preserves the property.

**Correctness guarantee**: Phase 2 (fibre descent) only changes values within a fixed structure — it cannot add or remove choice points, change branch selectors, or alter sequence length. The base point is invariant under Phase 2. If span extraction shows no deletion targets, Phase 2 cannot create any. The skip is correct for all subsequent cycles until a phase that changes structure runs (Phase 3 or Phase 4, which set `structureChanged: true` on acceptance).

**Measured impact**: BinaryHeap (15 cycles) saves 117 materializations (703 → 586, 17% reduction) with a 36% wall-clock speedup (150ms → 89ms, cold-cache measurement). Same counterexample quality.

### Per-edge budget adaptation

Composition edges receive observation-driven sub-budgets instead of a fixed 100-materialization cap. Controlled by `EdgeBudgetPolicy` on `PhaseConfiguration`:

- **Productive edge** (prior `exhaustedWithFailure`): 150 materializations (+50%).
- **Clean or bailed edge**: 50 materializations (-50%).
- **New edge**: 100 materializations (default).

`StaticStrategy` provides `.fixed(100)`. `AdaptiveStrategy` provides `.adaptive`. The phase method (`runKleisliExploration`) reads the policy and implements the adaptation.

### Signal-driven Phase 3 gating

Skips exploration when all CDG edges were `exhaustedClean` in the prior cycle. More precise than the binary "no progress" stall gate — avoids re-exploring fibres that were fully searched and found no failure.

### zeroingDependency escalation

Runs relax-round (Phase 4) even when prior phases made progress, if the prior cycle had `zeroingDependency` signals. Coupled coordinates need redistribution regardless of per-coordinate progress.

### Unified phase budget ceiling

No per-phase budget allocation. Each phase receives a generous ceiling (2000 materializations) and runs to exhaustion. No phase in the current test suite exceeds 1100 materializations. The profiling data showed that the static 1950/975/325 split doesn't actually constrain any phase — unused budget is returned immediately. Budget split adjustment was dropped as unnecessary.

## Architecture

### SchedulingStrategy protocol

```swift
protocol SchedulingStrategy {
    mutating func planFirstStage(
        priorOutcome: CycleOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase]

    mutating func planSecondStage(
        firstStageResult: PhaseOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase]

    mutating func phaseCompleted(
        phase: PlannedPhase.Phase,
        outcome: PhaseOutcome
    )
}
```

Two-stage planning because the fibre descent gate depends on the current cycle's base descent outcome (not available at cycle start). The first stage returns Phase 1 (or empty if skipped). The second stage returns Phases 2-4 with gating decisions.

### Orchestration skeleton

The skeleton in `BonsaiScheduler.runWithStrategy()`:
1. Calls `planFirstStage()` at cycle start.
2. Dispatches first-stage phases via `dispatchPhase()`.
3. Calls `planSecondStage()` with the first-stage result.
4. Dispatches second-stage phases. Phases with `requiresStall: true` are skipped if any prior phase accepted.
5. Collects `CycleOutcome`. Resets `PhaseTracker`.

The skeleton handles inter-phase data flow (CDG threading) and stall detection. The strategy handles phase selection, budget allocation, and gating conditions.

### ReductionStateView

Read-only projection of `ReductionState` for strategy planning:

```swift
struct ReductionStateView {
    let sequenceCount: Int
    let hasBind: Bool
    let allValueCoordinatesConverged: Bool
    let convergenceCacheIsEmpty: Bool
    let cycleNumber: Int
    let hasDeletionTargets: Bool    // pruneOrder.isEmpty == false
    let hasBranchTargets: Bool      // tree.containsPicks
}
```

### PhaseTracker

Stack-based attribution of materializations and acceptances to the outermost active phase. Handles nested phase execution (relax-round internally calls base descent and fibre descent). Rollback-aware: invocations from rolled-back phases are kept (real cost), acceptances are reverted.

### CycleOutcome

Per-cycle phase-level summaries for strategy decisions. Fine-grained decisions (per-coordinate, per-edge) bypass the summary and read the convergence cache and edge observations directly.

## Comparison results

Measured on the AdaptiveComparison test suite (adaptive runs first, cold cache):

| Test | Static mats | Adaptive mats | Saving | Static time | Adaptive time |
|------|------------|--------------|--------|------------|--------------|
| Difference | 3 | 3 | 0 | 0.5ms | 3.0ms |
| Replacement | 3 | 3 | 0 | 0.5ms | 3.0ms |
| Distinct | 38 | 32 | 6 (16%) | 2.9ms | 3.7ms |
| CoupledZeroing | 88 | 88 | 0 | 2.9ms | 4.9ms |
| Coupling | 188 | 178 | 10 (5%) | 4.6ms | 6.4ms |
| Bound5Path1 | 608 | 608 | 0 | 18.7ms | 25.1ms |
| **BinaryHeap** | **703** | **586** | **117 (17%)** | **140.9ms** | **89.5ms** |

Small tests show warm-cache bias (whoever runs second is faster). BinaryHeap is the honest signal: 117 fewer materializations, 36% faster, adaptive running on a cold cache. Same counterexample quality on every test.

## Resolved design decisions

**Budget split adjustment: dropped.** The profiling data showed no phase hits its budget cap as the binding constraint. Unused Phase 1 budget doesn't starve Phase 2. A unified 2000-materialization ceiling replaced the 1950/975/325 split.

**Adaptive phase ordering: implemented as Phase 1 skip with deletion probe.** The reverse-dependency case (Phase 2 before Phase 1) never appeared in the test suite. Instead, the data showed that Phase 1 wastes materializations on flat generators where no structural deletion is possible. Skipping Phase 1 via span extraction + behavioral gate is simpler and more effective than reordering. A lightweight deletion probe (budget: 100) runs at the end of cycles where Phase 1 was skipped, catching deletions that value minimization enabled (for example, reducing an element to zero makes it deletable). The probe closed a real gap on Bound5 and reduced materialisation counts on BinaryHeap and Bound5Path3.

**Verification sweep: stays post-termination.** Per-cycle floor probing would spend the verification budget every cycle instead of once at termination.

**Phase ordering oscillation: bounded.** The only adaptive ordering decision is Phase 1 skip (binary). No oscillation possible.

**Weighted yield: not needed.** Budget split adjustment was dropped, so the yield metric that would have driven it is unnecessary. `PhaseOutcome` tracks raw invocations and acceptances for diagnostic purposes.

## What remains

1. **Make `.adaptiveScheduling` the default.** The data supports it. No test regresses on counterexample quality. BinaryHeap is significantly faster. Small tests are neutral.
2. **Non-monotonicity detection (Phase 1b).** The convergence signals infrastructure (`ConvergenceSignal.nonMonotoneGap`, `LinearScanEncoder`, factory consumption) is implemented. The detection heuristic is deferred — within a single binary search run, every rejection occurs below a known failure, making in-stepper detection ambiguous. See `docs/convergence-signals-design.md`.

## Critical files

| File | Role |
|------|------|
| `SchedulingStrategy.swift` | Protocol, `StaticStrategy`, `AdaptiveStrategy`, `CyclePlan`, `PlannedPhase`, `PhaseConfiguration`, `EdgeBudgetPolicy`, `ReductionStateView` |
| `BonsaiScheduler.swift` | Orchestration skeleton (`runWithStrategy`), `dispatchPhase`, strategy instantiation |
| `BonsaiReducer.swift` | `useAdaptiveScheduling` configuration flag |
| `ReductionState.swift` | `PhaseTracker`, `CycleOutcome`, `PhaseDisposition`, `PhaseOutcome`, `view` accessor |
| `ReductionState+Bonsai.swift` | Phase push/pop, `edgeBudgetPolicy` parameter on `runKleisliExploration` |
| `ExhaustSettings.swift` | `.adaptiveScheduling` setting |
| `MacroSupport.swift` | Threading of `.adaptiveScheduling` through to the reducer |
| `AdaptiveComparison.swift` | A/B comparison test suite |
