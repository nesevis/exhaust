/// CDG-enhanced scheduling strategy that uses structural dependency metadata to improve two specific decisions within the adaptive pipeline.
///
/// Mirrors ``AdaptiveStrategy``'s cycle structure with two targeted additions:
///
/// 1. **Post-fibre deletion retry**: a second base descent pass after fibre descent retries deletions that became viable because fibre descent reduced bind-inner values. The reject cache doesn't block this because the sequence changed (different Zobrist hashes).
/// 2. **Level-ordered Kleisli edges**: composition edges are sorted by CDG topological level (parent-first) so child fibres are searched in the context of already-reduced parents.
///
/// For flat generators (no CDG nodes): both enhancements are inert — no deletion retry, no edges to reorder. The cycle is identical to ``AdaptiveStrategy``.
struct TopologicalStrategy: SchedulingStrategy {
  private static let phaseBudgetCeiling = 2000

  /// Budget for the post-fibre deletion retry pass.
  private static let deletionRetryBudget = 200

  // MARK: - Per-Cycle Tracking

  private var previousFibreProgress = true
  private var cycleImproved = false
  private var lastPriorOutcome: CycleOutcome?
  private var structuralMinimisationWasSkipped = false

  // MARK: - SchedulingStrategy

  var isForwardPassInProgress: Bool { false }

  mutating func planFirstStage(
    priorOutcome: CycleOutcome?,
    state: ReductionStateView
  ) -> [PlannedPhase] {
    cycleImproved = false
    lastPriorOutcome = priorOutcome

    // Same structural and behavioral gating as AdaptiveStrategy.
    let noTargets = state.hasDeletionTargets == false && state.hasBranchTargets == false
    let priorBaseUnproductive: Bool = {
      guard let prior = lastPriorOutcome else { return false }
      if case let .ran(outcome) = prior.baseDescent {
        return outcome.structuralAcceptances == 0
      }
      return true
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

    // Fibre descent gating (same condition as AdaptiveStrategy).
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

    // Enhancement 1: post-fibre deletion retry.
    // After fibre descent reduces bind-inner values, deletions that previously
    // failed may now succeed. The reject cache uses Zobrist hashes of the full
    // probe sequence, so changed values produce different hashes — no cache
    // blocking. Only runs when first-stage base descent actually ran (not
    // skipped) — if structural minimisation was skipped, no deletions were
    // attempted, so there is nothing to retry.
    if structuralMinimisationWasSkipped == false,
       state.dag != nil,
       state.hasDeletionTargets || state.hasBranchTargets
    {
      phases.append(PlannedPhase(
        phase: .baseDescent,
        budget: Self.deletionRetryBudget,
        configuration: PhaseConfiguration()
      ))
    }

    // Enhancement 2: level-ordered Kleisli edges.
    // Signal-driven exploration gating (same as AdaptiveStrategy), but with
    // levelOrderedEdges so parent edges run before child edges.
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
        configuration: PhaseConfiguration(
          edgeBudgetPolicy: .adaptive,
          levelOrderedEdges: true
        ),
        requiresStall: false
      ))
    }

    // Relax round with zeroingDependency escalation (same as AdaptiveStrategy).
    let hasZeroingDependency = (lastPriorOutcome?.zeroingDependencyCount ?? 0) > 0
    phases.append(PlannedPhase(
      phase: .relaxRound,
      budget: Self.phaseBudgetCeiling,
      configuration: PhaseConfiguration(),
      requiresStall: hasZeroingDependency == false
    ))

    // Deletion probe when structural minimisation was skipped (same as AdaptiveStrategy).
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
