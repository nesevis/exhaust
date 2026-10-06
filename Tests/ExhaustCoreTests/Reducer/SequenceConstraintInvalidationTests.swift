import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Sequence constraint source invalidation")
struct SequenceConstraintInvalidationTests {
    @Test("A changed root deletion floor invalidates structural cursors", arguments: [false, true])
    func deletionFloorChangeInvalidatesSources(reverse: Bool) {
        let deletableGraph = ChoiceGraph.build(from: sequence([10, 20], length: 0 ... 4))
        let fixedGraph = ChoiceGraph.build(from: sequence([10, 20], length: 2 ... 4))
        let oldGraph = reverse ? fixedGraph : deletableGraph
        let newGraph = reverse ? deletableGraph : fixedGraph
        let difference = ChoiceGraphDiff.diff(old: oldGraph, new: newGraph)

        #expect(RemovalQuery.elementRemovalScopes(graph: deletableGraph).count == 1)
        #expect(RemovalQuery.elementRemovalScopes(graph: fixedGraph).isEmpty)
        #expect(difference.added.isEmpty)
        #expect(difference.removed.isEmpty)
        #expect(difference.kindChangedPaths.isEmpty)
        #expect(difference.canReuseStructuralSources == false)
        #expect(difference.canReuseStructuralSourcesExceptPermutation == false)
    }

    @Test("A changed receiver capacity invalidates migration cursors", arguments: [false, true])
    func receiverCapacityChangeInvalidatesSources(reverse: Bool) {
        let fullGraph = ChoiceGraph.build(from: .group([
            sequence([10], length: 0 ... 2),
            sequence([20], length: 0 ... 1),
        ]))
        let availableGraph = ChoiceGraph.build(from: .group([
            sequence([10], length: 0 ... 2),
            sequence([20], length: 0 ... 2),
        ]))
        var fullCursor = MigrationCandidateSource(graph: fullGraph)
        var availableCursor = MigrationCandidateSource(graph: availableGraph)
        #expect(fullCursor.next(lastAccepted: false) == nil)
        #expect(availableCursor.next(lastAccepted: false) != nil)

        let oldGraph = reverse ? availableGraph : fullGraph
        let newGraph = reverse ? fullGraph : availableGraph
        let difference = ChoiceGraphDiff.diff(old: oldGraph, new: newGraph)
        #expect(difference.added.isEmpty)
        #expect(difference.removed.isEmpty)
        #expect(difference.kindChangedPaths.isEmpty)
        #expect(difference.canReuseStructuralSources == false)
    }

    @Test("Unchanged constraints retain value-only source reuse")
    func unchangedConstraintsAllowSourceReuse() {
        let oldGraph = ChoiceGraph.build(from: sequence([10, 20], length: 0 ... 4))
        let newGraph = ChoiceGraph.build(from: sequence([11, 21], length: 0 ... 4))
        let difference = ChoiceGraphDiff.diff(old: oldGraph, new: newGraph)

        #expect(difference.canReuseStructuralSources)
    }

    @Test("Constraint changes also prevent leaf-kind reuse")
    func constraintChangePreventsLeafKindReuse() {
        let oldGraph = ChoiceGraph.build(from: sequence([10], length: 0 ... 2))
        let newGraph = ChoiceGraph.build(from: .sequence(
            elements: [.just],
            metadata: .init(validRange: 1 ... 2, isRangeExplicit: true)
        ))
        let difference = ChoiceGraphDiff.diff(old: oldGraph, new: newGraph)

        #expect(difference.onlyLeafKindsChanged)
        #expect(difference.canReuseStructuralSourcesExceptPermutation == false)
    }

    @Test("A public bind can change the deletion floor without changing sequence shape")
    func publicBindConstraintChangeInvalidatesSources() throws {
        let generator = ReflectiveGenerator<Bool>.bool().bind { condition in
            ReflectiveGenerator(
                Gen.arrayOf(
                    Gen.choose(in: UInt64(0) ... 100),
                    within: condition ? 2 ... 4 : 0 ... 4,
                    scaling: .constant
                ),
                isReflective: true
            ).map { (condition, $0) }
        }
        var deletableTree: ChoiceTree?
        var fixedTree: ChoiceTree?
        for seed in UInt64(0) ..< 256 {
            var interpreter = ValueAndChoiceTreeInterpreter(
                generator.gen,
                materializePicks: false,
                seed: seed,
                maxRuns: 1
            )
            guard let (value, tree) = try interpreter.next(), value.1.count == 2 else {
                continue
            }
            switch value.0 {
                case false:
                    deletableTree = tree
                case true:
                    fixedTree = tree
            }
            if deletableTree != nil, fixedTree != nil {
                break
            }
        }
        let deletableGraph = try ChoiceGraph.build(from: #require(deletableTree))
        let fixedGraph = try ChoiceGraph.build(from: #require(fixedTree))
        let difference = ChoiceGraphDiff.diff(old: deletableGraph, new: fixedGraph)

        #expect(RemovalQuery.elementRemovalScopes(graph: deletableGraph).count == 1)
        #expect(RemovalQuery.elementRemovalScopes(graph: fixedGraph).isEmpty)
        #expect(difference.added.isEmpty)
        #expect(difference.removed.isEmpty)
        #expect(difference.kindChangedPaths.isEmpty)
        #expect(difference.preserved.allSatisfy { $0.value.oldNodeID == $0.value.newNodeID })
        #expect(difference.canReuseStructuralSources == false)
    }

    private func sequence(_ values: [UInt64], length: ClosedRange<UInt64>) -> ChoiceTree {
        .sequence(
            elements: values.map { .uint64($0, in: 0 ... 100) },
            metadata: .init(validRange: length, isRangeExplicit: true)
        )
    }
}
