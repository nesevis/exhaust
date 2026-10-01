import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reducer: lifted bind pivot stages")
struct GraphBindPivotStageTests {
    @Test("The lifted seed and range covering remain one ordered stage with the same sparse 64-position scope")
    func firstProbeThenScopedCovering() throws {
        let bound = ChoiceTree.group(
            [.int64(7)] + Array(repeating: .uint64(1, in: 0 ... 1), count: 65) + [.int64(9)]
        )
        let fixture = pivotFixture(bound: bound)
        let sequence = ChoiceSequence(fixture.lifted)
        let graph = ChoiceGraph.build(from: fixture.lifted)
        let boundChildID = try #require(graph.nodes[0].children.last)
        let boundRange = try #require(graph.nodes[boundChildID].positionRange)
        var original = BoundValueCoveringEncoder()
        original.start(sequence: sequence, tree: fixture.lifted, positionRange: boundRange)
        var expected: [ChoiceSequence] = []
        while let probe = original.nextProbe(lastAccepted: false) {
            expected.append(probe)
        }

        var encoder = BindPivotSearch.makeEncoder(lift: { _, _ in fixture.lifted })
        encoder.start(scope: fixture.scope)
        var buffer = fixture.scope.baseSequence
        var probes: [ChoiceSequence] = []
        while let mutation = encoder.nextProbe(into: &buffer, lastAccepted: false) {
            guard case .branchSelected(1, 0) = mutation else {
                Issue.record("Unexpected mutation \(mutation)")
                return
            }
            probes.append(buffer)
        }

        #expect(probes.first == sequence)
        #expect(Array(probes.dropFirst()) == expected)
        #expect(expected.isEmpty == false)
        #expect(encoder.ledger.attempts == 1)
        #expect(probes.allSatisfy { probe in
            let values = probe.compactMap(\.value)
            return values.count == 67
                && values[0].choice == ChoiceValue(Int64(7), tag: .int64)
                && values[65].choice == ChoiceValue(UInt64(1), tag: .uint64)
                && values[66].choice == ChoiceValue(Int64(9), tag: .int64)
        })
        #expect(expected.contains { $0.compactMap(\.value)[1].choice == ChoiceValue(UInt64(0), tag: .uint64) })
    }

    @Test("A lifted bound subtree without ranged leaves still emits its seed exactly once")
    func liftedProbeWithoutCoveringPositions() {
        let fixture = pivotFixture(bound: .int64(7))
        var encoder = BindPivotSearch.makeEncoder(lift: { _, _ in fixture.lifted })
        encoder.start(scope: fixture.scope)
        var buffer = fixture.scope.baseSequence

        guard case .branchSelected(1, 0)? = encoder.nextProbe(into: &buffer, lastAccepted: false) else {
            Issue.record("Expected the pivot mutation on the lifted seed")
            return
        }
        #expect(buffer == ChoiceSequence(fixture.lifted))
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
        #expect(encoder.ledger.attempts == 1)
    }
}

/// Keeps the bind at node zero and its inner pick at node one, so the mutation checks do not depend on scope discovery.
private func pivotFixture(bound: ChoiceTree) -> (scope: EncoderInput, lifted: ChoiceTree) {
    let branches: [ChoiceTree] = [.just, .uint64(99, in: 99 ... 99)]
    let original = ChoiceTree.bind(
        fingerprint: 1,
        inner: .pickSite(fingerprint: 2, selected: 1, branches: branches),
        bound: bound
    )
    let lifted = ChoiceTree.bind(
        fingerprint: 1,
        inner: .pickSite(fingerprint: 2, selected: 0, branches: branches),
        bound: bound
    )
    return (
        EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.bindPivot(.init(
                    bindNodeID: 0,
                    pickNodeID: 1,
                    targetBranchID: 0,
                    boundSubtreeSize: ChoiceSequence(bound).count,
                    estimatedProbes: 1
                ))),
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ),
            baseSequence: ChoiceSequence(original),
            tree: original,
            graph: ChoiceGraph.build(from: original),
            warmStartRecords: [:]
        ),
        lifted
    )
}
