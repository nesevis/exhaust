// MARK: - Scheduling Strategy

/// Provides scheduling decisions for the reduction cycle loop.
///
/// The orchestration skeleton in ``BonsaiScheduler`` dispatches phases in the order returned by the strategy. The strategy controls budget allocation, phase ordering, gating conditions, and per-phase configuration. The sole conformer is ``AdaptiveStrategy`` (signal-driven scheduling with per-edge budget adaptation).
///
/// Planning is split into two stages because the fibre descent gate depends on the current cycle's base descent outcome, which is not known at cycle start:
/// - ``planFirstStage(priorOutcome:state:)`` returns phases that run unconditionally (typically base descent).
/// - ``planSecondStage(firstStageResult:state:)`` returns remaining phases after the first stage completes.
protocol SchedulingStrategy {
    /// Plans the first phase(s) that run unconditionally at the start of each cycle.
    mutating func planFirstStage(
        priorOutcome: CycleOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase]

    /// Plans remaining phases after the first stage completes.
    ///
    /// - Parameter firstStageResult: The outcome of the first stage, or `nil` if the first stage was empty.
    mutating func planSecondStage(
        firstStageResult: PhaseOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase]

    /// Called after each phase completes (both stages).
    mutating func phaseCompleted(
        phase: PlannedPhase.Phase,
        outcome: PhaseOutcome
    )
}

/// A single phase to dispatch within a cycle.
struct PlannedPhase {
    /// Which phase to run.
    var phase: Phase

    /// Maximum property invocations allocated to this phase.
    var budget: Int

    /// Phase-specific configuration from the strategy.
    var configuration: PhaseConfiguration

    /// When true, the skeleton skips this phase if any prior phase in the cycle accepted probes.
    var requiresStall: Bool = false

    /// Identifies a reduction phase for scheduling dispatch.
    enum Phase: Hashable {
        case baseDescent
        case fibreDescent
        case exploration
    }
}

/// Per-phase configuration provided by the strategy.
///
/// Each phase reads its relevant fields. ``AdaptiveStrategy`` provides observation-driven values; the defaults serve as fallbacks.
struct PhaseConfiguration {
    /// How to allocate budget to composition edges in the exploration phase.
    var edgeBudgetPolicy: EdgeBudgetPolicy = .fixed(100)

    /// Optional scope restriction for the phase. When set, encoders only operate within this position range.
    var scopeRange: ClosedRange<Int>?

    /// When `true`, fibre descent clears the convergence cache before running.
    var clearConvergence = false

    /// Creates a default configuration.
    init(
        edgeBudgetPolicy: EdgeBudgetPolicy = .fixed(100),
        scopeRange: ClosedRange<Int>? = nil,
        clearConvergence: Bool = false
    ) {
        self.edgeBudgetPolicy = edgeBudgetPolicy
        self.scopeRange = scopeRange
        self.clearConvergence = clearConvergence
    }
}

/// Controls how budget is allocated to individual composition edges.
enum EdgeBudgetPolicy {
    /// Every edge gets the same sub-budget.
    case fixed(Int)
    /// Edge sub-budgets are adjusted based on prior-cycle edge observations.
    case adaptive
}

// MARK: - Reduction State View

/// Read-only projection of ``ReductionState`` for strategy planning decisions.
///
/// Exposes the signals the strategy needs without giving it mutable access to the reducer state.
struct ReductionStateView {
    /// Whether all value coordinates are at cached convergence floors or reduction targets.
    let allValueCoordinatesConverged: Bool

    /// The current cycle number.
    let cycleNumber: Int

    /// Whether any deletion encoder has applicable targets (non-empty `pruneOrder` after `computeEncoderOrdering()`).
    let hasDeletionTargets: Bool

    /// Whether the choice tree has branch nodes (picks) that branch simplification could operate on.
    let hasBranchTargets: Bool

    /// Whether the generator has bind operations.
    let hasBind: Bool

    /// The choice dependency graph built from the current sequence, or `nil` if no binds/picks.
    let dependencyGraph: ChoiceDependencyGraph?
}

// MARK: - Adaptive Strategy

/// Signal-driven scheduling strategy with per-edge budget adaptation.
///
/// - Each phase receives a generous ceiling (2000 materializations) and runs to exhaustion. No phase in the current test suite exceeds 1100 invocations — the ceiling is a safety limit, not a budget allocation decision.
/// - Composition edges receive observation-driven sub-budgets (productive +50%, clean/bail -50%).
/// - Structural minimization is skipped when span extraction shows no deletion targets and the prior cycle had zero structural acceptances.
/// - Cross-level minimization is skipped when all edges were `exhaustedClean` in the prior cycle.
/// - Speculative redistribution runs even when prior phases made progress if the prior cycle had `zeroingDependency` signals — coupled coordinates need redistribution regardless of per-coordinate progress.
struct AdaptiveStrategy: SchedulingStrategy {
    /// Generous per-phase ceiling. No phase in the current suite exceeds 1100 invocations.
    private static let phaseBudgetCeiling = 2000

    private var previousFibreProgress: Bool = true
    private var cycleImproved: Bool = false
    private var lastPriorOutcome: CycleOutcome?
    private var structuralMinimisationWasSkipped: Bool = false

    mutating func planFirstStage(
        priorOutcome: CycleOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase] {
        cycleImproved = false
        lastPriorOutcome = priorOutcome

        // Skip Phase 1 when structural work is provably absent or empirically unproductive.
        //
        // Structural gate: span extraction (already computed by computeEncoderOrdering)
        // shows no deletion targets and the tree has no branch nodes. Catches scalar
        // generators from cycle 1.
        //
        // Behavioral gate: the preceding cycle's Phase 1 had zero structural acceptances.
        // Catches array generators where deletion targets exist but no deletion preserves
        // the property. Phase 2 cannot create structural work — the base point is
        // invariant under value changes — so "no structural acceptances last cycle"
        // means "no structural acceptances this cycle" with certainty.
        //
        let noTargets = state.hasDeletionTargets == false && state.hasBranchTargets == false
        let priorBaseUnproductive: Bool = {
            guard let prior = lastPriorOutcome else { return false }
            if case let .ran(outcome) = prior.baseDescent {
                return outcome.structuralAcceptances == 0
            }
            return true // gated last cycle — still no work
        }()

        if noTargets || priorBaseUnproductive {
            structuralMinimisationWasSkipped = true
            return []
        } else {
            structuralMinimisationWasSkipped = false
            return [PlannedPhase(
                phase: .baseDescent,
                budget: Self.phaseBudgetCeiling,
                configuration: PhaseConfiguration()
            )]
        }
    }

    mutating func planSecondStage(
        firstStageResult: PhaseOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase] {
        let baseProgress = (firstStageResult?.acceptances ?? 0) > 0
        if baseProgress { cycleImproved = true }

        var phases: [PlannedPhase] = []

        // Fibre descent: gated when base descent ran and found nothing, fibre descent
        // found nothing in the prior cycle, all coordinates are converged, and it's not
        // the first cycle. When Phase 1 was skipped (firstStageResult is nil),
        // baseProgress is false — the gate still applies correctly.
        let fibreGated = baseProgress == false
            && previousFibreProgress == false
            && state.cycleNumber > 1
            && state.allValueCoordinatesConverged
        if fibreGated == false {
            phases.append(PlannedPhase(
                phase: .fibreDescent,
                budget: Self.phaseBudgetCeiling,
                configuration: PhaseConfiguration()
            ))
        }

        // Signal-driven Phase 3 gating: skip exploration when all edges
        // were exhaustedClean in the prior cycle. More precise than the
        // binary "no progress" gate — avoids re-exploring fibres that
        // were fully searched and found no failure.
        let allEdgesClean: Bool = {
            guard let prior = lastPriorOutcome,
                  prior.totalEdges > 0
            else { return false }
            return prior.exhaustedCleanEdges == prior.totalEdges
        }()

        if allEdgesClean == false {
            phases.append(PlannedPhase(
                phase: .exploration,
                budget: Self.phaseBudgetCeiling,
                configuration: PhaseConfiguration(edgeBudgetPolicy: .adaptive),
                requiresStall: false
            ))
        }

        // Deletion probe: when structural minimisation was skipped, value minimisation
        // may have reduced a value to zero or a no-op, making a previously-failed
        // deletion now viable. Run a lightweight structural pass at the end of the
        // cycle to catch this. Small budget — just enough for element deletions.
        if structuralMinimisationWasSkipped, state.hasDeletionTargets {
            phases.append(PlannedPhase(
                phase: .baseDescent,
                budget: 100,
                configuration: PhaseConfiguration()
            ))
        }

        return phases
    }

    mutating func phaseCompleted(
        phase: PlannedPhase.Phase,
        outcome: PhaseOutcome
    ) {
        if outcome.acceptances > 0 {
            cycleImproved = true
        }
        if phase == .fibreDescent {
            previousFibreProgress = outcome.acceptances > 0
        }
    }
}
