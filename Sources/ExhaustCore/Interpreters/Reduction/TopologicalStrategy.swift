/// Dependency-ordered scheduling strategy that walks the CDG topologically.
///
/// Each cycle focuses on the next unconverged CDG node in dependency order (roots first).
/// Base descent runs on the full sequence (structural encoders need full context), then
/// fibre descent and exploration are scoped to the current node's region. When a node
/// accepts changes, its dependents are marked dirty so they'll be revisited.
///
/// For flat generators (no CDG nodes), falls back to full-sequence phases identical
/// to ``AdaptiveStrategy``.
struct TopologicalStrategy: SchedulingStrategy {
  private static let phaseBudgetCeiling = 2000

  // MARK: - Topological Walk State

  /// Node indices from the CDG's topological order. Rebuilt when the DAG changes.
  private var nodeQueue: [Int] = []

  /// Current position in the node queue. Advances each cycle.
  private var queuePosition = 0

  /// Nodes that stalled (no progress on last visit). Skipped until a dependency makes progress.
  private var convergedNodes: Set<Int> = []

  /// The DAG from the last cycle, used to detect when the DAG changes (structural acceptance).
  private var lastNodeCount = 0

  /// Scope range for the current node's fibre descent and exploration.
  private var currentNodeScope: ClosedRange<Int>?

  /// Dependent node indices for the current node (to dirty on progress).
  private var currentNodeDependents: [Int] = []

  // MARK: - Phase Tracking

  private var currentCycleImproved = false
  private var previousFibreProgress = true
  private var previousCycleStalled = false

  // MARK: - SchedulingStrategy

  mutating func planFirstStage(
    priorOutcome: CycleOutcome?,
    state: ReductionStateView
  ) -> [PlannedPhase] {
    previousCycleStalled = currentCycleImproved == false && state.cycleNumber > 1
    currentCycleImproved = false

    // Rebuild the topological walk when the DAG changes or on first cycle.
    if let dag = state.dag {
      let nodeCount = dag.nodes.count
      if nodeCount != lastNodeCount || state.cycleNumber <= 1 {
        nodeQueue = dag.topologicalOrder
        queuePosition = 0
        convergedNodes.removeAll()
        lastNodeCount = nodeCount
      }
    }

    // Advance to the next unconverged node.
    advanceToNextUnconvergedNode(dag: state.dag)

    // Base descent always runs on the full sequence — structural encoders
    // (promotion, pivot, deletion) need the full tree context.
    guard state.hasDeletionTargets || state.hasBranchTargets else {
      return []
    }

    if let prior = priorOutcome,
       case let .ran(outcome) = prior.baseDescent,
       outcome.structuralAcceptances == 0
    {
      return []
    }

    return [PlannedPhase(
      phase: .baseDescent,
      budget: Self.phaseBudgetCeiling,
      configuration: PhaseConfiguration()
    )]
  }

  mutating func planSecondStage(
    firstStageResult: PhaseOutcome?,
    state: ReductionStateView
  ) -> [PlannedPhase] {
    let baseProgress = (firstStageResult?.acceptances ?? 0) > 0
    if baseProgress {
      currentCycleImproved = true
      // Structural change invalidates the walk — all nodes need revisiting.
      convergedNodes.removeAll()
    }

    var phases: [PlannedPhase] = []

    // If we have a current node scope, focus fibre descent and exploration on it.
    // Otherwise fall back to full-sequence (flat generator or exhausted queue).
    let scopeConfig = currentNodeScope.map {
      PhaseConfiguration(scopeRange: $0)
    } ?? PhaseConfiguration()

    // Fibre descent: always full-sequence. Batch zeroing needs the full picture
    // to coordinate coupled values (e.g. add(X, Y) where X + Y = 0 requires
    // both zeroed simultaneously). Scoping would break batch coordination.
    // After a stall, clear convergence so batch zeroing retries with fresh state —
    // Kleisli may have set values externally that the cache doesn't reflect.
    let fibreGated = baseProgress == false
      && previousFibreProgress == false
      && state.cycleNumber > 1
      && state.allValueCoordinatesConverged
      && previousCycleStalled == false
    if fibreGated == false {
      phases.append(PlannedPhase(
        phase: .fibreDescent,
        budget: Self.phaseBudgetCeiling,
        configuration: PhaseConfiguration(clearConvergence: previousCycleStalled)
      ))
    }

    // Exploration: scoped to current node's edges when available.
    let explorationConfig = PhaseConfiguration(
      edgeBudgetPolicy: .adaptive,
      scopeRange: currentNodeScope
    )
    phases.append(PlannedPhase(
      phase: .exploration,
      budget: Self.phaseBudgetCeiling,
      configuration: explorationConfig,
      requiresStall: currentNodeScope == nil
    ))

    // Relax round.
    phases.append(PlannedPhase(
      phase: .relaxRound,
      budget: Self.phaseBudgetCeiling,
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
      currentCycleImproved = true
      // Progress on this node: dirty its dependents so they'll be revisited.
      for dependent in currentNodeDependents {
        convergedNodes.remove(dependent)
      }
    }
    if phase == .fibreDescent {
      previousFibreProgress = outcome.acceptances > 0
    }
    // If fibre descent and exploration both stalled, mark this node converged.
    if phase == .exploration, outcome.acceptances == 0, currentCycleImproved == false {
      if queuePosition < nodeQueue.count {
        convergedNodes.insert(nodeQueue[queuePosition])
      }
    }
  }

  // MARK: - Private

  /// Advances `queuePosition` past converged nodes to the next one that needs work.
  private mutating func advanceToNextUnconvergedNode(dag: ChoiceDependencyGraph?) {
    currentNodeScope = nil
    currentNodeDependents = []

    guard let dag, nodeQueue.isEmpty == false else { return }

    // Wrap around when we reach the end of the queue.
    var attempts = 0
    while attempts < nodeQueue.count {
      let wrappedPosition = (queuePosition + attempts) % nodeQueue.count
      let nodeIndex = nodeQueue[wrappedPosition]

      if convergedNodes.contains(nodeIndex) == false {
        queuePosition = wrappedPosition
        let node = dag.nodes[nodeIndex]
        currentNodeScope = node.scopeRange
        currentNodeDependents = dag.nodes[nodeIndex].dependents
        return
      }
      attempts += 1
    }

    // All nodes converged — fall back to full-sequence phases.
    currentNodeScope = nil
    currentNodeDependents = []
  }
}
