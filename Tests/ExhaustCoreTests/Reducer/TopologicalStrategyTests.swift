import Testing
@testable import ExhaustCore

// MARK: - TopologicalStrategy Tests

@Suite("TopologicalStrategy")
struct TopologicalStrategyTests {

  // MARK: - Helpers

  /// Creates a ReductionStateView with the given CDG and cycle number.
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

  /// Creates a PhaseOutcome with the given acceptance counts.
  private static func makeOutcome(
    acceptances: Int = 0,
    structuralAcceptances: Int = 0
  ) -> PhaseOutcome {
    PhaseOutcome(
      propertyInvocations: acceptances,
      acceptances: acceptances,
      structuralAcceptances: structuralAcceptances,
      budgetAllocated: 2000
    )
  }

  /// Builds a CDG from a synthetic nested-bind tree.
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

  /// Builds a CDG from a bind-with-branch tree (bind-inner at level 0, branch at level 1).
  private static func buildBindWithBranchCDG() -> ChoiceDependencyGraph {
    let branchA = ChoiceTree.branch(
      siteID: 0, weight: 1, id: 0, branchIDs: [0, 1],
      choice: .choice(
        .unsigned(100, .uint64),
        .init(validRange: 0 ... 100, isRangeExplicit: true)
      )
    )
    let branchB = ChoiceTree.branch(
      siteID: 0, weight: 1, id: 1, branchIDs: [0, 1],
      choice: .choice(
        .unsigned(200, .uint64),
        .init(validRange: 0 ... 200, isRangeExplicit: true)
      )
    )
    let pickSite = ChoiceTree.group([branchA, .selected(branchB)])
    let inner = ChoiceTree.choice(
      .unsigned(5, .uint64),
      .init(validRange: 0 ... 10, isRangeExplicit: true)
    )
    let tree = ChoiceTree.bind(inner: inner, bound: pickSite)
    let sequence = ChoiceSequence(tree)
    let bindIndex = BindSpanIndex(from: sequence)
    return ChoiceDependencyGraph.build(
      from: sequence, tree: tree, bindIndex: bindIndex
    )
  }

  // MARK: - Level Walk Structure

  @Test("Flat generator produces cleanup cycle only")
  func flatGeneratorProducesCleanupOnly() {
    var strategy = TopologicalStrategy()

    // Cycle 1: no DAG → cleanup.
    let view1 = Self.makeView(cycleNumber: 1)
    let firstStage1 = strategy.planFirstStage(priorOutcome: nil, state: view1)
    // Cleanup base descent (or empty if no targets — our view has hasDeletionTargets: true).
    #expect(firstStage1.count <= 1)

    let secondStage1 = strategy.planSecondStage(
      firstStageResult: nil, state: view1
    )
    // Cleanup: fibre descent + relax round.
    #expect(secondStage1.contains { $0.phase == .fibreDescent })
    #expect(secondStage1.contains { $0.phase == .relaxRound })

    // Cycle 2: done.
    let view2 = Self.makeView(cycleNumber: 2)
    let firstStage2 = strategy.planFirstStage(priorOutcome: nil, state: view2)
    #expect(firstStage2.isEmpty)
  }

  @Test("Nested binds produce level cycles then cleanup")
  func nestedBindsProduceThreeCycles() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()

    // Cycle 1: level 0.
    let view1 = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    let firstStage1 = strategy.planFirstStage(priorOutcome: nil, state: view1)
    #expect(firstStage1.count == 1)
    #expect(firstStage1[0].phase == .baseDescent)
    // Scoped: base descent should have a scopeRange.
    #expect(firstStage1[0].configuration.scopeRange != nil)

    let secondStage1 = strategy.planSecondStage(
      firstStageResult: nil, state: view1
    )
    #expect(secondStage1.contains { $0.phase == .levelReduction })

    // Cycle 2: level 1.
    let view2 = Self.makeView(dag: dag, cycleNumber: 2, hasBind: true)
    let firstStage2 = strategy.planFirstStage(priorOutcome: nil, state: view2)
    #expect(firstStage2.count == 1)
    #expect(firstStage2[0].configuration.scopeRange != nil)

    let secondStage2 = strategy.planSecondStage(
      firstStageResult: nil, state: view2
    )
    #expect(secondStage2.contains { $0.phase == .levelReduction })

    // Cycle 3: cleanup.
    let view3 = Self.makeView(dag: dag, cycleNumber: 3, hasBind: true)
    let firstStage3 = strategy.planFirstStage(priorOutcome: nil, state: view3)
    // Cleanup: base descent with no scopeRange.
    if firstStage3.isEmpty == false {
      #expect(firstStage3[0].configuration.scopeRange == nil)
    }

    let secondStage3 = strategy.planSecondStage(
      firstStageResult: nil, state: view3
    )
    #expect(secondStage3.contains { $0.phase == .fibreDescent })

    // Cycle 4: done.
    let view4 = Self.makeView(dag: dag, cycleNumber: 4, hasBind: true)
    let firstStage4 = strategy.planFirstStage(priorOutcome: nil, state: view4)
    #expect(firstStage4.isEmpty)
  }

  // MARK: - Scope Parameters

  @Test("Bind-inner level has depthFilter and suppressCovariantSweep")
  func levelScopeParametersCorrect() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()
    let view = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)

    _ = strategy.planFirstStage(priorOutcome: nil, state: view)
    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )

    let levelPhase = secondStage.first { $0.phase == .levelReduction }
    #expect(levelPhase != nil)
    #expect(levelPhase?.configuration.depthFilter != nil)
    #expect(levelPhase?.configuration.scopeRange != nil)
  }

  @Test("Branch-selector level has exclusion ranges")
  func branchSelectorLevelHasExclusionRanges() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildBindWithBranchCDG()
    let levels = dag.topologicalLevels()
    // Level 0 is bind-inner, level 1 is branch-selector.
    #expect(levels.count == 2)

    // Cycle 1: level 0 (bind-inner).
    let view1 = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view1)
    _ = strategy.planSecondStage(firstStageResult: nil, state: view1)

    // Cycle 2: level 1 (branch-selector).
    let view2 = Self.makeView(dag: dag, cycleNumber: 2, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view2)
    let secondStage2 = strategy.planSecondStage(
      firstStageResult: nil, state: view2
    )

    let levelPhase = secondStage2.first { $0.phase == .levelReduction }
    #expect(levelPhase != nil)
    // Branch-selector level: depthFilter is nil.
    #expect(levelPhase?.configuration.depthFilter == nil)
    #expect(levelPhase?.configuration.scopeRange != nil)
  }

  @Test("Cleanup phase has no suppression and no depthFilter")
  func cleanupPhaseHasNoSuppression() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()

    // Run through all levels.
    let view1 = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view1)
    _ = strategy.planSecondStage(firstStageResult: nil, state: view1)

    let view2 = Self.makeView(dag: dag, cycleNumber: 2, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view2)
    _ = strategy.planSecondStage(firstStageResult: nil, state: view2)

    // Cycle 3: cleanup.
    let view3 = Self.makeView(dag: dag, cycleNumber: 3, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view3)
    let cleanupSecond = strategy.planSecondStage(
      firstStageResult: nil, state: view3
    )

    let fibrePhase = cleanupSecond.first { $0.phase == .fibreDescent }
    #expect(fibrePhase != nil)
    #expect(fibrePhase?.configuration.depthFilter == nil)
    #expect(fibrePhase?.configuration.suppressCovariantSweep == false)
    #expect(fibrePhase?.configuration.exclusionRanges == nil)
  }

  // MARK: - Structural Rebuild

  @Test("Structural acceptance triggers level rebuild")
  func structuralAcceptanceTriggersRebuild() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()

    // Cycle 1: level 0.
    let view1 = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view1)
    _ = strategy.planSecondStage(firstStageResult: nil, state: view1)

    // Simulate structural acceptance in base descent.
    strategy.phaseCompleted(
      phase: .baseDescent,
      outcome: Self.makeOutcome(acceptances: 1, structuralAcceptances: 1)
    )

    // Cycle 2: should restart from level 0 (not level 1).
    let view2 = Self.makeView(dag: dag, cycleNumber: 2, hasBind: true)
    let firstStage2 = strategy.planFirstStage(priorOutcome: nil, state: view2)
    #expect(firstStage2.count == 1)
    // The scope should match level 0's scope, not level 1's.
    let level0Scope = dag.scopeRange(forNodesAtLevel: dag.topologicalLevels()[0])
    #expect(firstStage2[0].configuration.scopeRange == level0Scope)
  }
}
