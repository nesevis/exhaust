/// Level-ordered scheduling strategy that walks CDG topological levels.
///
/// Each cycle processes one topological level of the CDG as a scoped sub-cycle
/// (base descent → fibre descent → exploration → redistribution). After all levels
/// complete, a full-sequence cleanup pass runs. The scheduler's stall budget handles
/// termination.
///
/// For bind-inner levels, the sub-cycle uses exclusive scope via `depthFilter` — only
/// values at the bind-inner's depth are processed. For branch-selector levels,
/// `depthFilter` is nil and an exclusion set prevents premature convergence of
/// deeper-level positions.
///
/// For flat generators (no CDG nodes), the level walk is empty and only the cleanup
/// pass runs — functionally identical to ``AdaptiveStrategy``.
struct TopologicalStrategy: SchedulingStrategy {
  private static let phaseBudgetCeiling = 2000

  // MARK: - Level Walk State

  /// Topological levels from the CDG. Each element is an array of node indices at that level.
  private var levels: [[Int]] = []

  /// Index into `levels` for the next level to process. Advances after each level's sub-cycle.
  private var currentLevelIndex = 0

  /// When `true`, the level walk is complete and the next cycle is the cleanup pass.
  private var isCleanupCycle = false

  /// When `true`, the cleanup pass has run and no more work remains.
  private var isDone = false

  /// Set by `phaseCompleted` when a structural acceptance occurs. The next `planFirstStage`
  /// rebuilds levels from the fresh DAG and resets to level 0.
  private var needsRebuild = false

  // MARK: - Per-Cycle Tracking

  private var currentCycleImproved = false
  private var previousFibreProgress = true

  // MARK: - Current Level Scope

  /// Scope parameters computed in `planFirstStage`, consumed by `planSecondStage`.
  private var currentScopeRange: ClosedRange<Int>?
  private var currentDepthFilter: Int?
  private var currentExclusionRanges: [ClosedRange<Int>]?
  private var currentSuppressCovariantSweep = false

  // MARK: - SchedulingStrategy

  mutating func planFirstStage(
    priorOutcome: CycleOutcome?,
    state: ReductionStateView
  ) -> [PlannedPhase] {
    currentCycleImproved = false

    // Rebuild levels on first cycle or after structural acceptance.
    if needsRebuild || state.cycleNumber <= 1 {
      if let dag = state.dag {
        levels = dag.topologicalLevels()
      } else {
        levels = []
      }
      currentLevelIndex = 0
      isCleanupCycle = false
      isDone = false
      needsRebuild = false
    }

    guard isDone == false else { return [] }

    if isCleanupCycle {
      // Cleanup cycle: full-sequence base descent (no scoping).
      return planCleanupBaseDescent(state: state)
    }

    if currentLevelIndex >= levels.count {
      // Level walk complete → transition to cleanup.
      isCleanupCycle = true
      clearCurrentLevelScope()
      return planCleanupBaseDescent(state: state)
    }

    guard let dag = state.dag else {
      // No DAG → skip directly to cleanup.
      isCleanupCycle = true
      clearCurrentLevelScope()
      return planCleanupBaseDescent(state: state)
    }

    // Compute scope for the current level.
    let nodeIndices = levels[currentLevelIndex]
    currentScopeRange = dag.scopeRange(forNodesAtLevel: nodeIndices)

    guard let scope = currentScopeRange else {
      // Level has no scope (all nodes have nil scopeRange) — skip to next level.
      currentLevelIndex += 1
      return planFirstStage(priorOutcome: priorOutcome, state: state)
    }

    computeLevelScope(dag: dag, nodeIndices: nodeIndices, scopeRange: scope)

    // Base descent scoped to this level.
    return [PlannedPhase(
      phase: .baseDescent,
      budget: Self.phaseBudgetCeiling,
      configuration: PhaseConfiguration(scopeRange: currentScopeRange)
    )]
  }

  mutating func planSecondStage(
    firstStageResult: PhaseOutcome?,
    state: ReductionStateView
  ) -> [PlannedPhase] {
    let baseProgress = (firstStageResult?.acceptances ?? 0) > 0
    if baseProgress { currentCycleImproved = true }

    if isCleanupCycle {
      return planCleanupSecondStage(baseProgress: baseProgress, state: state)
    }

    guard isDone == false else { return [] }

    // Level sub-cycle: fibre descent, exploration, redistribution — all scoped.
    var phases: [PlannedPhase] = []

    let levelConfig = PhaseConfiguration(
      scopeRange: currentScopeRange,
      depthFilter: currentDepthFilter,
      suppressCovariantSweep: currentSuppressCovariantSweep,
      exclusionRanges: currentExclusionRanges
    )

    // Fibre descent: scoped to level.
    let fibreGated = baseProgress == false
      && previousFibreProgress == false
      && state.cycleNumber > 1
      && state.allValueCoordinatesConverged
    if fibreGated == false {
      phases.append(PlannedPhase(
        phase: .fibreDescent,
        budget: Self.phaseBudgetCeiling,
        configuration: levelConfig
      ))
    }

    // Exploration: scoped to level's edges.
    phases.append(PlannedPhase(
      phase: .exploration,
      budget: Self.phaseBudgetCeiling,
      configuration: PhaseConfiguration(
        edgeBudgetPolicy: .adaptive,
        scopeRange: currentScopeRange
      )
    ))

    // Redistribution: scoped to level.
    phases.append(PlannedPhase(
      phase: .relaxRound,
      budget: Self.phaseBudgetCeiling,
      configuration: PhaseConfiguration(scopeRange: currentScopeRange),
      requiresStall: true
    ))

    // Advance to next level for the next cycle.
    currentLevelIndex += 1

    return phases
  }

  mutating func phaseCompleted(
    phase: PlannedPhase.Phase,
    outcome: PhaseOutcome
  ) {
    if outcome.acceptances > 0 {
      currentCycleImproved = true
    }
    if phase == .fibreDescent {
      previousFibreProgress = outcome.acceptances > 0
    }
    // Structural acceptance triggers rebuild on next planFirstStage.
    if outcome.structuralAcceptances > 0 {
      needsRebuild = true
    }
  }

  // MARK: - Private

  /// Computes `depthFilter`, `suppressCovariantSweep`, and `exclusionRanges` for the current level.
  private mutating func computeLevelScope(
    dag: ChoiceDependencyGraph,
    nodeIndices: [Int],
    scopeRange: ClosedRange<Int>
  ) {
    let hasBindInner = nodeIndices.contains { index in
      if case .structural(.bindInner) = dag.nodes[index].kind { return true }
      return false
    }
    let hasBranchSelector = nodeIndices.contains {
      dag.nodes[$0].kind == .structural(.branchSelector)
    }

    if hasBindInner, hasBranchSelector == false {
      // Pure bind-inner level: exclusive scope via depthFilter.
      let firstBindInner = nodeIndices.first { index in
        if case .structural(.bindInner) = dag.nodes[index].kind { return true }
        return false
      }!
      currentDepthFilter = dag.nodes[firstBindInner].bindDepth
      currentSuppressCovariantSweep = true
      currentExclusionRanges = nil
    } else {
      // Branch-selector or mixed-type level: no depthFilter, use exclusion set.
      currentDepthFilter = nil
      currentSuppressCovariantSweep = true
      currentExclusionRanges = dag.exclusionRanges(
        forLevel: currentLevelIndex,
        levels: levels,
        scopeRange: scopeRange
      )
    }
  }

  /// Resets the current level scope fields to their unscoped defaults.
  private mutating func clearCurrentLevelScope() {
    currentScopeRange = nil
    currentDepthFilter = nil
    currentExclusionRanges = nil
    currentSuppressCovariantSweep = false
  }

  /// Plans base descent for the cleanup cycle, with structural gates.
  private func planCleanupBaseDescent(
    state: ReductionStateView
  ) -> [PlannedPhase] {
    guard state.hasDeletionTargets || state.hasBranchTargets else {
      return []
    }
    return [PlannedPhase(
      phase: .baseDescent,
      budget: Self.phaseBudgetCeiling,
      configuration: PhaseConfiguration()
    )]
  }

  /// Plans second-stage phases for the cleanup cycle (full-sequence, no suppression).
  private mutating func planCleanupSecondStage(
    baseProgress: Bool,
    state: ReductionStateView
  ) -> [PlannedPhase] {
    var phases: [PlannedPhase] = []

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

    phases.append(PlannedPhase(
      phase: .relaxRound,
      budget: Self.phaseBudgetCeiling,
      configuration: PhaseConfiguration(),
      requiresStall: true
    ))

    isDone = true
    return phases
  }
}
