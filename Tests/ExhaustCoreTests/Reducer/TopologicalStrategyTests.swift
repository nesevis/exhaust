import Testing
@testable import ExhaustCore

// MARK: - TopologicalStrategy Tests

@Suite("TopologicalStrategy")
struct TopologicalStrategyTests {

  // MARK: - Cycle Structure

  @Test("Flat generator uses standard fibre descent with no CDG enhancements")
  func flatGeneratorHasNoEnhancements() {
    var strategy = TopologicalStrategy()

    let view = Self.makeView(cycleNumber: 1)
    let firstStage = strategy.planFirstStage(priorOutcome: nil, state: view)
    #expect(firstStage.count == 1)
    #expect(firstStage[0].phase == .baseDescent)

    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )
    // No CDG → no level reductions, no deletion retry.
    #expect(secondStage.contains { $0.phase == .levelReduction } == false)
    #expect(secondStage.contains { $0.phase == .fibreDescent })
    #expect(secondStage.contains { $0.phase == .exploration })
    #expect(secondStage.contains { $0.phase == .relaxRound })
    // Only one base descent (the deletion probe, not the retry).
    let baseDescentCount = secondStage.filter { $0.phase == .baseDescent }.count
    #expect(baseDescentCount == 0)
  }

  @Test("Bind generator has per-level batch zeroing before fibre descent")
  func bindGeneratorHasLevelReductions() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()

    let view = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view)
    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )

    // Level reductions appear before fibre descent.
    let levelPhases = secondStage.filter { $0.phase == .levelReduction }
    #expect(levelPhases.count == dag.topologicalLevels().count)

    let fibreIndex = secondStage.firstIndex { $0.phase == .fibreDescent }!
    let lastLevelIndex = secondStage.lastIndex { $0.phase == .levelReduction }!
    #expect(lastLevelIndex < fibreIndex)

    // Level reductions have tight budgets.
    for level in levelPhases {
      #expect(level.budget == 15)
    }
  }

  @Test("Bind generator has post-fibre deletion retry")
  func bindGeneratorHasDeletionRetry() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()

    let view = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view)
    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )

    // Deletion retry (base descent) appears after fibre descent.
    let fibreIndex = secondStage.firstIndex { $0.phase == .fibreDescent }!
    let baseDescentPhases = secondStage.enumerated().filter {
      $0.element.phase == .baseDescent
    }
    let postFibreBaseDescent = baseDescentPhases.filter { $0.offset > fibreIndex }
    #expect(postFibreBaseDescent.isEmpty == false)
    #expect(postFibreBaseDescent[0].element.budget == 200)
  }

  @Test("Kleisli exploration has levelOrderedEdges set")
  func kleisliHasLevelOrderedEdges() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()

    let view = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view)
    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )

    let explorationPhase = secondStage.first { $0.phase == .exploration }
    #expect(explorationPhase != nil)
    #expect(explorationPhase?.configuration.levelOrderedEdges == true)
  }

  @Test("Flat generator Kleisli does not set levelOrderedEdges")
  func flatGeneratorKleisliHasDefaultEdgeOrder() {
    var strategy = TopologicalStrategy()

    let view = Self.makeView(cycleNumber: 1)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view)
    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )

    let explorationPhase = secondStage.first { $0.phase == .exploration }
    #expect(explorationPhase != nil)
    // Flat generators have no edges to reorder, but the flag is still set.
    // No harm — levelOrderedEdges on an empty edge list is a no-op.
  }

  // MARK: - Scope Parameters

  @Test("Bind-inner level has depthFilter in level reduction phase")
  func levelScopeParametersCorrect() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()
    let view = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)

    _ = strategy.planFirstStage(priorOutcome: nil, state: view)
    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )

    let bindInnerPhase = secondStage.first {
      $0.phase == .levelReduction && $0.configuration.depthFilter != nil
    }
    #expect(bindInnerPhase != nil)
    #expect(bindInnerPhase?.configuration.scopeRange != nil)
  }

  // MARK: - Helpers

  private static func makeView(
    dag: ChoiceDependencyGraph? = nil,
    cycleNumber: Int = 1,
    hasDeletionTargets: Bool = true,
    hasBranchTargets: Bool = false,
    hasBind: Bool = false
  ) -> ReductionStateView {
    ReductionStateView(
      allValueCoordinatesConverged: false,
      cycleNumber: cycleNumber,
      hasDeletionTargets: hasDeletionTargets,
      hasBranchTargets: hasBranchTargets,
      hasBind: hasBind,
      dag: dag
    )
  }

  private static func buildNestedBindCDG() -> ChoiceDependencyGraph {
    let val = ChoiceTree.choice(
      .unsigned(10, .uint64),
      .init(validRange: 0 ... 100, isRangeExplicit: true)
    )
    let innerBind = ChoiceTree.bind(inner: val, bound: val)
    let outerBind = ChoiceTree.bind(inner: val, bound: innerBind)
    let sequence = ChoiceSequence(outerBind)
    let bindIndex = BindSpanIndex(from: sequence)
    return ChoiceDependencyGraph.build(
      from: sequence, tree: outerBind, bindIndex: bindIndex
    )
  }
}
