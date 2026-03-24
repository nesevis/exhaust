# Closed-Loop Reducer Design

## Motivation

The current `BonsaiScheduler` runs a fixed phase sequence — structural deletion → value minimization → Kleisli exploration → relax-round — with move-to-front promotion as the only adaptation. Budget allocation is static (6:3:1 ratio). Phase gating uses a four-condition heuristic. Stall detection counts consecutive non-improving cycles.

This works well for the current test suite. The profiling data in `reduction-planning.md` confirms: zero staleness detected, zero convergence transfers exercised, the fibre descent gate already skips Phase 2 when all coordinates are converged, and the existing binary gating (Phases 3+4 only when Phases 1+2 stall) already adapts in the most impactful case.

The closed-loop design is deliberate forward-looking infrastructure. This library actively pushes at the boundary of what is possible in property-based testing — deeply nested binds, data-dependent fibres, non-monotone failure surfaces, coupled constraints that defeat per-coordinate search. The composable encoder algebra was built for the same reason: not because existing generators required it, but because the architecture must be ready when generators do. The closed loop is the scheduling counterpart to the encoder algebra's search counterpart.

**What the profiling data does support today:**
- **Per-edge budget adaptation.** Composition edges get a fixed 100-materialisation sub-budget regardless of productivity. Profiling shows futile edges (Coupling: `futile=2`, WideCDG: `futile=2`) alongside productive edges (CrossLevelSum: `edges=2, futile=1`).
- **Signal-driven edge skipping.** Already implemented (`exhaustedClean` skip). Extending this to Phase 3 gating is a natural next step.

**What the profiling data does not yet support:**
- Budget rebalancing between Phases 1 and 2.
- Adaptive phase ordering (the reverse-dependency case).
- Fine-grained stall classification.

These are not measured problems on the current suite. They are architectural capabilities the closed loop provides for generators that will exercise them.

## What the closed loop changes

The outer-loop logic in `BonsaiScheduler.runCore()` — phase ordering, budget allocation, gating conditions. It does NOT change:

- The composable encoder algebra (`ComposableEncoder`, `KleisliComposition`, `DownstreamPick`)
- The factory's encoder selection (`EncoderFactory`, `MorphismDescriptor`, descriptor chains)
- The convergence cache, edge observations, or convergence signals
- The verification sweep (post-termination)
- The projection phase (one-shot structural isolation)
- The phase methods themselves (`runBaseDescent`, `runFibreDescent`, `runKleisliExploration`, `runRelaxRound`)

## Instrumentation: what exists and what is missing

The design depends on per-phase outcome data that the codebase does not currently track.

### What exists

- `ReductionStats` (ReductionStats.swift) tracks aggregate counters: `totalMaterializations`, `encoderProbes` by name, convergence signal counts, edge observation counts. No per-phase breakdown.
- `accept()` (ReductionState.swift:359) receives `structureChanged: Bool` for cache invalidation. No acceptance counter.
- Property invocations are counted externally at the macro runtime level, not inside the reducer.
- Per-phase progress is tracked via local `anyAccepted: Bool` flags (ReductionState+Bonsai.swift:710, 980, 1031) that collapse to a single boolean.

### What is missing

- Per-phase acceptance counts (structural vs value).
- Per-phase property invocation counts.
- Phase identity at the `accept()` call site — the method doesn't know which phase called it.

### Instrumentation cost

Adding per-phase counters requires threading a phase identifier through every `accept()` call — approximately 20 call sites across four phase methods, each with different rollback semantics. Rolled-back phases (Kleisli exploration at line 1222, relax-round at line 806) consumed real property invocations but produced zero net acceptances. `PhaseOutcome` must count both: invocations spent (real cost) and acceptances survived (net progress). This is not a trivial change — the rollback logic in each phase method must correctly attribute invocations to the phase that spent them, even when the phase's net result is rolled back.

The approach: add a `PhaseTracker` struct to `ReductionState` that accumulates per-phase invocations and acceptances. Each phase method pushes the active phase at entry and pops at exit (stack-based). `accept()` increments the active phase's acceptance counter. `runComposable` and `runDescriptorChain` increment the active phase's invocation counter on each materialisation. On rollback, invocations are kept (they happened), acceptances are reverted (the improvements were undone).

**Nesting semantics.** Relax-round (Phase 4) internally calls `runBaseDescent()` and `runFibreDescent()` during its exploitation pipeline. With stack-based attribution, the outermost phase is the attribution target — the exploitation sub-calls are attributed to Phase 4, not to Phases 1 and 2. This is correct for budget decisions: the strategy allocated budget to Phase 4 and needs to know how much Phase 4 consumed, including its internal exploitation. If the sub-calls were attributed to Phases 1 and 2, those phases would show invocations from budget they were not allocated.

## Cycle state

`CycleOutcome` captures phase-level summaries for budget and ordering decisions. Fine-grained decisions (per-coordinate, per-edge) bypass `CycleOutcome` and read the convergence cache and edge observations directly — the summary is intentionally lossy at the phase level because per-edge and per-coordinate decisions need detail (which edge, which coordinate) that counts cannot provide.

```swift
struct CycleOutcome {
    var baseDescent: PhaseDisposition
    var fibreDescent: PhaseDisposition
    var exploration: PhaseDisposition
    var relaxRound: PhaseDisposition

    /// Aggregate convergence signal summary from Phase 2 (phase-level decisions only).
    var zeroingDependencyCount: Int
    var monotoneConvergenceCount: Int

    /// Aggregate edge observation summary from Phase 3 (phase-level decisions only).
    /// Per-edge budget adaptation reads `edgeObservations` directly.
    var exhaustedCleanEdges: Int
    var exhaustedWithFailureEdges: Int
    var totalEdges: Int

    var improved: Bool
    var cycle: Int
}

/// Distinguishes "the scheduler chose not to run this phase" from
/// "the scheduler ran this phase and it produced nothing."
/// Budget allocation treats these differently: gated phases retain
/// prior budget; stalled phases lose budget.
enum PhaseDisposition {
    case ran(PhaseOutcome)
    case gated(reason: GateReason)
}

enum GateReason {
    case allCoordinatesConverged
    case noProgress
    case allEdgesClean
}

struct PhaseOutcome {
    /// Property invocations — the uniform cost measure across all phases.
    /// Every phase pays the same cost per invocation regardless of whether
    /// the invocation involves a lift (Phase 3), a materialisation (Phase 2),
    /// or a direct sequence mutation (Phase 1).
    var propertyInvocations: Int

    var acceptances: Int
    var structuralAcceptances: Int
    var budgetAllocated: Int

    var utilization: Double {
        budgetAllocated > 0 ? Double(propertyInvocations) / Double(budgetAllocated) : 0
    }
}
```

Note: `weightedYield` is deliberately omitted from `PhaseOutcome`. The structural-to-value acceptance weight depends on instrumentation data that does not exist yet. The weight may be a static parameter, a per-run adaptive value, or the wrong abstraction entirely — the instrumentation data will reveal which. The yield computation is the strategy's responsibility, not the outcome struct's.

## Implementation approach

### `SchedulingStrategy` protocol (Phase 2 of migration)

The orchestration skeleton is extracted from `runCore()` early — in Phase 2, immediately after instrumentation. `StaticStrategy` freezes the current `BonsaiScheduler` behavior as the regression baseline. Every subsequent phase adds adaptation to `AdaptiveStrategy` while `StaticStrategy` remains untouched.

**Why early extraction.** The alternative — modifying `BonsaiScheduler` directly in Phases 2-3 and extracting the protocol later — means the comparison baseline shifts with each phase. Phase 3 compares against the Phase 2 modification, not against the original scheduler. If Phase 3 regresses, it's unclear whether the regression is from Phase 3's change or from Phase 2's. With early extraction, every phase compares `AdaptiveStrategy` against the frozen `StaticStrategy` — a fixed reference point. The abstraction cost is paid once; the A/B rigor applies to every subsequent phase. This is the same logic that motivated the composable encoder algebra: build the infrastructure early so that incremental changes are testable in isolation.

```swift
/// The skeleton calls `plan()` once at the start of each cycle, dispatches
/// phases in `CyclePlan` order, calls `phaseCompleted()` once per dispatched
/// phase in dispatch order, then collects `CycleOutcome` and feeds it to the
/// next cycle's `plan()`. Conformers may maintain cross-cycle state (for
/// example, `previousFibreProgress` in `StaticStrategy`); the call-order
/// contract guarantees that `phaseCompleted()` is called in a consistent
/// sequence relative to `plan()`.
protocol SchedulingStrategy {
    mutating func plan(
        priorOutcome: CycleOutcome?,
        state: ReductionState<some Any>
    ) -> CyclePlan

    mutating func phaseCompleted(
        phase: PlannedPhase.Phase,
        outcome: PhaseOutcome,
        state: ReductionState<some Any>
    )
}

/// The schedule for one reduction cycle: which phases run, in what order, with what budgets.
struct CyclePlan {
    var phases: [PlannedPhase]
}

struct PlannedPhase {
    /// Which phase to run. Uses the same identifiers as the phase methods
    /// on ReductionState (baseDescent, fibreDescent, exploration, relaxRound).
    var phase: Phase

    /// Maximum property invocations allocated to this phase.
    var budget: Int

    /// Phase-specific configuration from the strategy.
    /// The skeleton passes this to the phase method; the phase method
    /// interprets it. This is how the strategy controls phase-internal
    /// behavior without modifying the phase method itself.
    var configuration: PhaseConfiguration

    enum Phase {
        case baseDescent
        case fibreDescent
        case exploration
        case relaxRound
    }
}

/// Per-phase configuration provided by the strategy.
///
/// Each phase reads its relevant field. `StaticStrategy` provides
/// the default values (`.fixed(100)` for edge budget, and so on).
/// `AdaptiveStrategy` provides observation-driven values.
struct PhaseConfiguration {
    /// How to allocate budget to composition edges in Phase 3.
    var edgeBudgetPolicy: EdgeBudgetPolicy = .fixed(100)
}

enum EdgeBudgetPolicy {
    /// Every edge gets the same sub-budget.
    case fixed(Int)
    /// Edge sub-budgets are adjusted based on prior-cycle edge observations.
    /// The phase method reads `edgeObservations` and applies the adaptation.
    case adaptive
}
```

The `plan` → dispatch → `phaseCompleted` cycle captures concern 1 (which phases, what budgets). The orchestration skeleton handles concern 2 (data flow: the CDG produced by Phase 1, threaded to Phases 2 and 3) and concern 3 (cross-cycle state: `previousFibreProgress`). The skeleton hardcodes the data-flow dependencies — with four phases and two data-flow edges, this is accepted pragmatism, not a design flaw. If the phase count grows, the abstraction boundary is revisited.

**CDG re-derivation.** If `CyclePlan` orders Phase 2 before Phase 1, the skeleton re-derives the CDG after Phase 1 completes (before dispatching Phase 3). Cost: O(regions + edges) — needs benchmarking on deeply nested generators before the Phase 2-first path is committed to.

**StaticStrategy equivalence.** The `StaticStrategy` conformer must produce byte-identical final sequences AND identical intermediate probe sequences (validated by diffing per-probe sequence hashes) for all seeds vs the current `BonsaiScheduler`. This validates the extraction — any divergence is a bug in the protocol wiring. This criterion applies only to `StaticStrategy` clone validation, not to `AdaptiveStrategy` comparison.

**Protocol value.** The `SchedulingStrategy` protocol's value is both structural and behavioral from Phase 3 onward. Structurally, it provides the frozen `StaticStrategy` as the A/B comparison baseline. Behaviorally, per-edge budget adaptation (Phase 3) is activated by `EdgeBudgetPolicy.adaptive` on `PhaseConfiguration` — the strategy selects the policy in `plan()`, the skeleton passes it to `runKleisliExploration`, and the phase method implements the adaptation. `StaticStrategy` provides `.fixed(100)` and the phase method behaves identically to the pre-Phase-3 code. Signal-driven gating (Phase 4) exercises `plan()` more deeply by changing the phase list in `CyclePlan`.

## Proposed adaptations

### Per-edge budget adaptation (highest priority)

Controlled by `EdgeBudgetPolicy` on `PhaseConfiguration`. `StaticStrategy` provides `.fixed(100)` (current behavior). `AdaptiveStrategy` provides `.adaptive`, and `runKleisliExploration` reads `edgeObservations` to determine per-edge sub-budgets. The phase method contains the adaptation logic; the strategy activates it. This preserves the `StaticStrategy` freeze — the phase method behaves differently based on the policy it receives, not based on which strategy is active.

Per-edge budget rules under `.adaptive`:

- **Productive edge** (prior: `exhaustedWithFailure`): increase budget by 50%.
- **Clean edge** (prior: `exhaustedClean`, same upstream value, structurally constant): skip.
- **Fallback edge** (downstream used ZeroValue via `DownstreamPick`): maintain budget if productive, reduce if persistently unproductive.
- **New edge** (no prior observation): default budget.

This is the most immediately justified adaptation. It also produces the first concrete measurement of whether observation-driven adaptation improves the reducer — the testable hypothesis for the closed loop.

### Signal-driven Phase 3 gating (second priority)

Extend the existing Phases 3+4 stall gate: if all CDG edges have `exhaustedClean` observations at the same upstream values, skip Phase 3 entirely. This replaces the binary "no progress" check with a signal-based check. The `CycleOutcome` summary fields are sufficient.

The `zeroingDependency → Phase 4` escalation is a gating change (run Phase 4 when `zeroingDependencyCount > 0` regardless of Phase 3's outcome), not a reordering change. It does not require `CyclePlan` — it's a predicate on the existing gating logic.

### Budget split adjustment (third priority, contingent on measurement)

Adjust the 1950/975/325 static split based on prior-cycle phase outcomes. The mechanism depends on instrumentation data:

- If the structural-to-value ratio is stable across generator classes, a yield-based shift (proportional to the gap between phase yields, with a dead zone to prevent oscillation on near-equal yields) is appropriate.
- If the ratio varies wildly, a per-run adaptive weight (computed from the current run's phase outcomes) is needed.
- If neither approach improves on the static split, the static split stands.

The budget shift granularity, dead zone threshold, and adaptive weight computation are all design decisions that depend on Phase 1 instrumentation data. They are not specified here.

### Adaptive phase ordering (lowest priority, contingent on evidence)

Not implemented until a generator that exhibits the reverse-dependency pattern (value reduction unlocking structural deletion) is added to the structural pathological tests and the fixed ordering is shown to produce a measurably worse counterexample. The `SchedulingStrategy` protocol supports it. The CDG re-derivation cost needs benchmarking.

## Escalation policy

Signal-driven escalation refines the existing gating predicates:

- **Phase 2 → Phase 3.** When all Phase 2 coordinates are at cached floors AND at least one CDG edge is not `exhaustedClean`, run Phase 3.
- **Phase 2 → Phase 4.** When `zeroingDependencyCount > 0`, run Phase 4 regardless of Phase 3's outcome.
- **Phase 3 → Phase 2 re-prioritization.** When Phase 3 produces `exhaustedWithFailure`, the current architecture re-runs Phase 2 naturally.

Stall counts remain as the termination condition.

## Termination and verification

Unchanged. Verification sweep stays post-termination.

## Ordering constraints

- **Phase 1 before Phase 3.** The CDG is derived from the sequence. Structural changes invalidate it.
- **Phase 2 before Phase 3.** Phase 2 settles fibre coordinates that compositions operate on.
- **Phase 1 ↔ Phase 2**: the only adaptive ordering decision. Subject to CDG re-derivation after Phase 1.
- **Phase 3 ↔ Phase 4**: adaptive, no data-flow constraint.

## Open questions

1. **Instrumentation threading cost.** Adding per-phase counters requires threading a phase identifier through ~20 `accept()` call sites. The rollback semantics (Kleisli, relax-round) complicate attribution. Scoped `PhaseTracker` with rollback-aware counting is the proposed approach. Validate on a small phase method first.

2. **Structural weight distribution.** The structural-to-value acceptance weight may vary by generator class. If flat generators show 0:N and nested generators show M:1, a static weight is the wrong abstraction. Instrumentation data determines whether a static weight, a per-run adaptive weight, or no weight (raw acceptance count) is appropriate. Do not commit to an interface until the distribution is known.

3. **Per-test regression bounds.** No test should regress by more than 10% or 20 invocations, whichever is larger. The floor prevents small-test noise from blocking phases.

4. **CDG re-derivation cost at scale.** O(regions + edges) is negligible for the current suite. For deeply nested generators (the target), benchmark before committing to the Phase 2-first path.

5. **Move-to-front interaction.** If budget rebalancing reduces Phase 2's budget, move-to-front has less time to stabilize. The minimum phase budget must allow at least one full descriptor chain pass.

## Concrete consumer: three new generators

The closed loop needs generators that exercise its capabilities. Add three generators to the structural pathological test suite in Phase 2 of migration (alongside the `SchedulingStrategy` extraction):

1. **A generator where per-edge budget adaptation matters.** Multiple CDG edges with varying productivity — one productive edge, one futile edge, one intermittently productive edge. The fixed 100-materialisation sub-budget should demonstrably misallocate vs adaptive allocation.
2. **A generator where signal-driven Phase 3 gating matters.** A CDG where all edges become `exhaustedClean` after a few cycles. The current stall gate should demonstrably run Phase 3 after the edges are exhausted vs the signal-driven gate skipping it.
3. **A generator where `zeroingDependency` escalation matters.** Coupled coordinates where batch zeroing fails but individual zeroing succeeds, and redistribution (Phase 4) resolves the coupling. The current Phase 3 → Phase 4 ordering should demonstrably delay resolution vs `zeroingDependency` escalation.

**Sizing constraint.** Each generator must require at least 500 total materializations under `StaticStrategy`, so that a meaningful improvement (50+ materializations saved) is unambiguously outside the noise floor (the 20-invocation tolerance minimum). A generator small enough that the fixed sub-budget is close to the tolerance floor cannot produce measurable signal.

These generators turn the intrinsic-value argument into testable hypotheses. If the adaptive scheduling produces no measurable improvement on these generators, the design is wrong — not premature, wrong.

## Migration path

Each phase has an explicit off-ramp. The off-ramp for the overall effort: if Phase 3 (per-edge adaptation in `AdaptiveStrategy`) produces no measurable improvement on the three new generators vs `StaticStrategy`, the remaining phases do not proceed.

### Phase 1: Instrumentation

Add `PhaseTracker` to `ReductionState`. Thread phase identity through `accept()` and materialisation paths. Collect `CycleOutcome` per cycle. Log to `ExhaustReport`. No scheduling changes.

Measure:
- Per-phase acceptance counts (structural vs value).
- Per-phase property invocation counts (including rolled-back invocations).
- Per-edge observation distribution.
- Structural-to-value acceptance ratio distribution across generator classes.

**Off-ramp:** If all phases are already well-balanced, proceed to Phase 2 anyway — the instrumentation has intrinsic diagnostic value.

### Phase 2: `SchedulingStrategy` protocol + `StaticStrategy` + three new generators

Extract the orchestration skeleton from `runCore()` into the `SchedulingStrategy` protocol. Implement `StaticStrategy` that reproduces the current behavior exactly.

Clone validation: `StaticStrategy` must produce byte-identical final sequences and identical intermediate probe sequences (per-probe hash diffing) vs the pre-extraction `BonsaiScheduler` for all seeds. This validates the extraction — any divergence is a wiring bug. Cross-reference `CycleOutcome` data against `ExhaustReport` to validate outcome collection correctness.

Add the three new generators to the structural pathological suite (per-edge budget, signal-driven gating, `zeroingDependency` escalation).

**Off-ramp:** N/A — the protocol extraction is a refactor with no behavioral change. The new generators are tests, not production code. Always proceed.

### Phase 3: Per-edge budget adaptation

Implement `AdaptiveStrategy` with per-edge budget adaptation (reads `edgeObservations`, adjusts per-edge sub-budget). `StaticStrategy` remains frozen. Compare against `StaticStrategy` per the comparison methodology: counterexample quality must match or beat (hard), property invocations and materializations within 10% per-test tolerance (soft), net improvement across composition-heavy tests expected.

**Off-ramp:** If per-edge adaptation produces no measurable improvement on the new generators, stop. The fixed sub-budget is sufficient and the closed-loop design needs rethinking.

### Phase 4: Signal-driven gating

Add signal-driven Phase 3 gating and `zeroingDependency` escalation to `AdaptiveStrategy`. Compare against `StaticStrategy`: does the signal-driven gate skip Phase 3 earlier? Does `zeroingDependency` escalation resolve coupled coordinates faster?

**Off-ramp:** If the stall gate already handles these cases effectively, stop.

### Phase 5: Budget split adjustment

Implement yield-based budget shift between Phases 1 and 2 in `AdaptiveStrategy`. The mechanism depends on Phase 1 instrumentation data — static weight, adaptive weight, or raw counts. Compare: per-test improvement and regression.

**Off-ramp:** If the static split is near-optimal, stop.

### Phase 6: Adaptive phase ordering (contingent)

Only if a reverse-dependency generator exists and the fixed ordering is shown to produce a worse counterexample. CDG re-derivation cost must be benchmarked.

**Off-ramp:** If no reverse-dependency generator is found, this phase does not proceed.

### Comparison methodology

Each phase compares `AdaptiveStrategy` against the frozen `StaticStrategy` on the full shrinking challenge suite with identical seeds.

**Hard constraints (per-test, every test must pass):**
- **Counterexample quality**: `AdaptiveStrategy` must produce a counterexample at least as minimal (shortlex) as `StaticStrategy`. Any quality regression blocks the phase.

**Soft constraints (per-test, 10% or 20 invocations tolerance, whichever is larger):**
- **Property invocations**: no test regresses by more than 10% or 20 invocations, whichever is larger. The floor prevents small-test noise (a 2-probe regression on a 17-probe test is 11.8% but meaningless) from blocking phases while still catching meaningful regressions on large tests. The goal is a net improvement across the suite; individual tests may regress within the tolerance.
- **Materializations**: same tolerance (10% or 20, whichever is larger).

**Informational metrics (no constraint, used for diagnosis):**
- **Cycle count**: fewer is better, but not a gate.
- **Signal utilization**: how often `AdaptiveStrategy`'s decisions differ from `StaticStrategy`'s, and whether those differences produced better or worse outcomes. Diagnoses whether the adaptation is active and directionally correct.
