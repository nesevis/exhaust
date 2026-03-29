/// CDG-enhanced scheduling strategy that uses structural dependency metadata to improve specific decisions within the adaptive pipeline.
///
/// Mirrors ``AdaptiveStrategy``'s cycle structure with level-ordered Kleisli edges as the sole CDG enhancement. Composition edges are sorted by CDG topological level (parent-first) so child fibres are searched in the context of already-reduced parents.
///
/// For flat generators (no CDG nodes): the enhancement is inert — no edges to reorder. The cycle is identical to ``AdaptiveStrategy``.
struct TopologicalStrategy: SchedulingStrategy {
  private static let phaseBudgetCeiling = 2000

  // MARK: - Per-Cycle Tracking

  private var previousFibreProgress = true
  private var cycleImproved = false
  private var lastPriorOutcome: CycleOutcome?
  private var structuralMinimisationWasSkipped = false

  /// Fingerprint at the last cycle where base descent ran.
  private var lastBaseDescentFingerprint: StructuralFingerprint?

  // MARK: - SchedulingStrategy

  var isForwardPassInProgress: Bool { false }

  mutating func planFirstStage(
    priorOutcome: CycleOutcome?,
    state: ReductionStateView
  ) -> [PlannedPhase] {
    cycleImproved = false
    lastPriorOutcome = priorOutcome

    // Same gating as AdaptiveStrategy, including fingerprint gate.
    let noTargets = state.hasDeletionTargets == false && state.hasBranchTargets == false
    let priorBaseUnproductive: Bool = {
      guard let prior = lastPriorOutcome else { return false }
      if case let .ran(outcome) = prior.baseDescent {
        return outcome.structuralAcceptances == 0
      }
      return true
    }()
    let fingerprintStale: Bool = {
      guard let current = state.structuralFingerprint,
            let last = lastBaseDescentFingerprint
      else { return false }
      return current == last
    }()

    if noTargets || priorBaseUnproductive || fingerprintStale {
      structuralMinimisationWasSkipped = true
      return []
    } else {
      structuralMinimisationWasSkipped = false
      lastBaseDescentFingerprint = state.structuralFingerprint
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

    // Level-ordered Kleisli edges.
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

    // Deletion probe — fingerprint-gated (same as AdaptiveStrategy).
    let deletionProbeGated: Bool = {
      guard let current = state.structuralFingerprint,
            let last = lastBaseDescentFingerprint
      else { return false }
      return current == last
    }()
    if structuralMinimisationWasSkipped, state.hasDeletionTargets, deletionProbeGated == false {
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
    if outcome.structuralAcceptances > 0 {
      lastBaseDescentFingerprint = nil
    }
  }
}
