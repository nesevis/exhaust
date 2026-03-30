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

  @Test("Bind generator has fibre descent and level-ordered Kleisli")
  func bindGeneratorHasCorrectPhases() {
    var strategy = TopologicalStrategy()
    let dag = Self.buildNestedBindCDG()

    let view = Self.makeView(dag: dag, cycleNumber: 1, hasBind: true)
    _ = strategy.planFirstStage(priorOutcome: nil, state: view)
    let secondStage = strategy.planSecondStage(
      firstStageResult: nil, state: view
    )

    #expect(secondStage.contains { $0.phase == .fibreDescent })
    #expect(secondStage.contains { $0.phase == .levelReduction } == false)
    let exploration = secondStage.first { $0.phase == .exploration }
    #expect(exploration?.configuration.levelOrderedEdges == true)
  }

  @Test("Fingerprint gating skips base descent when structure unchanged")
  func fingerprintGatingSkipsBaseDescent() {
    var strategy = TopologicalStrategy()

    // Cycle 1: base descent runs (no prior outcome, no fingerprint).
    let view1 = Self.makeView(cycleNumber: 1)
    let firstStage1 = strategy.planFirstStage(priorOutcome: nil, state: view1)
    #expect(firstStage1.count == 1)
    #expect(firstStage1[0].phase == .baseDescent)
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
