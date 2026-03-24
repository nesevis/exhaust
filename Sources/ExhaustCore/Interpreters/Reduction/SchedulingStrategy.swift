// MARK: - Scheduling Strategy

/// Provides scheduling decisions for the reduction cycle loop.
///
/// The orchestration skeleton in ``BonsaiScheduler`` dispatches phases in the order returned by the strategy. The strategy controls budget allocation, phase ordering, gating conditions, and per-phase configuration. Two conformers: ``StaticStrategy`` (behavioral clone of the current fixed scheduler) and ``AdaptiveStrategy`` (signal-driven, future).
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

// MARK: - Cycle Plan

/// The schedule for one reduction cycle: which phases run, in what order, with what budgets.
struct CyclePlan {
    var phases: [PlannedPhase]
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
        case relaxRound
    }
}

/// Per-phase configuration provided by the strategy.
///
/// Each phase reads its relevant fields. ``StaticStrategy`` provides default values. ``AdaptiveStrategy`` provides observation-driven values.
struct PhaseConfiguration {
    /// How to allocate budget to composition edges in the exploration phase.
    var edgeBudgetPolicy: EdgeBudgetPolicy = .fixed(100)

    /// Creates a default configuration.
    init(edgeBudgetPolicy: EdgeBudgetPolicy = .fixed(100)) {
        self.edgeBudgetPolicy = edgeBudgetPolicy
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
    /// Number of entries in the current choice sequence.
    let sequenceCount: Int

    /// Whether the generator has bind operations.
    let hasBind: Bool

    /// Whether all value coordinates are at cached convergence floors or reduction targets.
    let allValueCoordinatesConverged: Bool

    /// Whether the convergence cache has any entries.
    let convergenceCacheIsEmpty: Bool

    /// The current cycle number.
    let cycleNumber: Int
}

// MARK: - Static Strategy

/// Reproduces the current ``BonsaiScheduler`` behavior exactly.
///
/// Fixed phase ordering (base descent → fibre descent → exploration → relax-round), static budgets (1950/975/325), four-condition fibre descent gate, binary Phases 3+4 gating. This is the regression baseline — it must produce byte-identical results to the pre-extraction scheduler.
struct StaticStrategy: SchedulingStrategy {
    /// Tracks Phase 2 progress across cycles for the fibre descent gate.
    private var previousFibreProgress: Bool = true

    /// Whether the current cycle has seen any improvement from dispatched phases.
    private var cycleImproved: Bool = false

    mutating func planFirstStage(
        priorOutcome: CycleOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase] {
        cycleImproved = false
        // Base descent always runs.
        return [
            PlannedPhase(
                phase: .baseDescent,
                budget: BonsaiScheduler.baseDescentBudget,
                configuration: PhaseConfiguration()
            )
        ]
    }

    mutating func planSecondStage(
        firstStageResult: PhaseOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase] {
        let baseProgress = (firstStageResult?.acceptances ?? 0) > 0
        if baseProgress { cycleImproved = true }

        var phases: [PlannedPhase] = []

        // Fibre descent: gated by four-condition check.
        let fibreGated = baseProgress == false
            && previousFibreProgress == false
            && state.cycleNumber > 1
            && state.allValueCoordinatesConverged
        if fibreGated == false {
            phases.append(PlannedPhase(
                phase: .fibreDescent,
                budget: BonsaiScheduler.fibreDescentBudget,
                configuration: PhaseConfiguration()
            ))
        }

        // Phases 3+4: gated on stall — the skeleton skips these if any prior
        // phase in the cycle accepted probes.
        phases.append(PlannedPhase(
            phase: .exploration,
            budget: BonsaiScheduler.relaxRoundBudget,
            configuration: PhaseConfiguration(),
            requiresStall: true
        ))
        phases.append(PlannedPhase(
            phase: .relaxRound,
            budget: BonsaiScheduler.relaxRoundBudget,
            configuration: PhaseConfiguration(),
            requiresStall: true
        ))

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

// MARK: - Adaptive Strategy

/// Signal-driven scheduling strategy with per-edge budget adaptation.
///
/// Differences from ``StaticStrategy``:
/// - Composition edges receive observation-driven sub-budgets (productive +50%, clean/bail -50%).
/// - Phase 3 (exploration) is skipped when all edges were `exhaustedClean` in the prior cycle.
/// - Phase 4 (relax-round) runs even when prior phases made progress if the prior cycle had `zeroingDependency` signals — coupled coordinates need redistribution regardless of per-coordinate progress.
struct AdaptiveStrategy: SchedulingStrategy {
    private var previousFibreProgress: Bool = true
    private var cycleImproved: Bool = false
    private var lastPriorOutcome: CycleOutcome?

    mutating func planFirstStage(
        priorOutcome: CycleOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase] {
        cycleImproved = false
        lastPriorOutcome = priorOutcome
        return [
            PlannedPhase(
                phase: .baseDescent,
                budget: BonsaiScheduler.baseDescentBudget,
                configuration: PhaseConfiguration()
            )
        ]
    }

    mutating func planSecondStage(
        firstStageResult: PhaseOutcome?,
        state: ReductionStateView
    ) -> [PlannedPhase] {
        let baseProgress = (firstStageResult?.acceptances ?? 0) > 0
        if baseProgress { cycleImproved = true }

        var phases: [PlannedPhase] = []

        // Fibre descent: same four-condition gate as StaticStrategy.
        let fibreGated = baseProgress == false
            && previousFibreProgress == false
            && state.cycleNumber > 1
            && state.allValueCoordinatesConverged
        if fibreGated == false {
            phases.append(PlannedPhase(
                phase: .fibreDescent,
                budget: BonsaiScheduler.fibreDescentBudget,
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
                budget: BonsaiScheduler.relaxRoundBudget,
                configuration: PhaseConfiguration(edgeBudgetPolicy: .adaptive),
                requiresStall: true
            ))
        }

        // zeroingDependency escalation: run relax-round even when prior phases
        // made progress, if the prior cycle detected coupled coordinates where
        // batch zeroing failed but individual zeroing succeeded. Redistribution
        // is the natural recovery path for coupled coordinates.
        let hasZeroingDependency = (lastPriorOutcome?.zeroingDependencyCount ?? 0) > 0
        phases.append(PlannedPhase(
            phase: .relaxRound,
            budget: BonsaiScheduler.relaxRoundBudget,
            configuration: PhaseConfiguration(),
            requiresStall: hasZeroingDependency == false
        ))

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

