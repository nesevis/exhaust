import Testing
@testable import ExhaustCore

@Suite("Encoder Probe Sequences")
struct EncoderIsolationTests {

    // MARK: - GraphValueEncoder

    @Test("Value encoder binary search narrows toward zero on rejection")
    func valueEncoderBinarySearchNarrows() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(80 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        guard let scope = minimizationScope(tree: tree, graph: graph) else {
            Issue.record("No minimization scope found")
            return
        }

        var encoder = GraphValueEncoder()
        encoder.start(scope: scope)

        var probeValues: [UInt64] = []
        while let probe = encoder.nextProbe(lastAccepted: false) {
            let values = probe.candidate.compactMap { $0.value?.choice.bitPattern64 }
            if let first = values.first {
                probeValues.append(first)
            }
        }

        #expect(probeValues.isEmpty == false)
        #expect(probeValues[0] == 0)
    }

    @Test("Value encoder narrows search window after rejection")
    func valueEncoderNarrowsAfterRejection() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(100 as UInt64, tag: .uint64), .init(validRange: 0 ... 200, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        guard let scope = minimizationScope(tree: tree, graph: graph) else {
            Issue.record("No minimization scope found")
            return
        }

        var encoder = GraphValueEncoder()
        encoder.start(scope: scope)

        var probeValues: [UInt64] = []
        while let probe = encoder.nextProbe(lastAccepted: false) {
            let values = probe.candidate.compactMap { $0.value?.choice.bitPattern64 }
            if let first = values.first {
                probeValues.append(first)
            }
        }

        #expect(probeValues.count >= 2)
        if probeValues.count >= 2 {
            #expect(probeValues[1] > probeValues[0], "Second probe should be higher than first (binary search midpoint)")
        }
    }

    @Test("Value encoder terminates after exhausting binary search budget")
    func valueEncoderTerminates() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(50 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        guard let scope = minimizationScope(tree: tree, graph: graph) else {
            Issue.record("No minimization scope found")
            return
        }

        var encoder = GraphValueEncoder()
        encoder.start(scope: scope)

        var probeCount = 0
        while encoder.nextProbe(lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(probeCount > 0)
        #expect(probeCount < 100)
    }

    // MARK: - GraphStructuralEncoder (Removal)

    @Test("Removal encoder produces strictly shorter candidates")
    func removalProducesShortherCandidates() {
        let tree = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = removalScope(tree: tree, graph: graph) else {
            Issue.record("No removal scope found")
            return
        }

        var encoder = GraphStructuralEncoder()
        encoder.start(scope: scope)

        while let probe = encoder.nextProbe(lastAccepted: false) {
            #expect(probe.candidate.count < sequence.count)
        }
    }

    @Test("Removal encoder tries progressively smaller batches on rejection")
    func removalTriesSmallerBatches() {
        let tree = ChoiceTree.sequence(
            length: 4,
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(4 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let graph = ChoiceGraph.build(from: tree)
        let baseSequence = ChoiceSequence.flatten(tree)

        guard let scope = removalScope(tree: tree, graph: graph) else {
            Issue.record("No removal scope found")
            return
        }

        var encoder = GraphStructuralEncoder()
        encoder.start(scope: scope)

        var candidateLengths: [Int] = []
        while let probe = encoder.nextProbe(lastAccepted: false) {
            candidateLengths.append(probe.candidate.count)
        }

        #expect(candidateLengths.isEmpty == false)
        let removedCounts = candidateLengths.map { baseSequence.count - $0 }
        for index in removedCounts.indices.dropFirst() {
            #expect(removedCounts[index] <= removedCounts[index - 1], "Batch size should not increase on rejection")
        }
    }
}

// MARK: - Helpers

private func minimizationScope(
    tree: ChoiceTree,
    graph: ChoiceGraph
) -> TransformationScope? {
    let sequence = ChoiceSequence.flatten(tree)
    let scopes = MinimizationScopeQuery.build(graph: graph)
    guard let firstScope = scopes.first else { return nil }
    let transformation = GraphTransformation(
        operation: .minimize(firstScope),
        yield: TransformationYield(
            structural: 0,
            value: 0,
            slack: .exact,
            estimatedProbes: 10
        ),
        precondition: .unconditional,
        postcondition: TransformationPostcondition(
            isStructural: false,
            invalidatesConvergence: [],
            enablesRemoval: []
        )
    )
    return TransformationScope(
        transformation: transformation,
        baseSequence: sequence,
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}

private func removalScope(
    tree: ChoiceTree,
    graph: ChoiceGraph
) -> TransformationScope? {
    let sequence = ChoiceSequence.flatten(tree)
    let scopes = RemovalScopeQuery.elementRemovalScopes(graph: graph)
    guard let firstScope = scopes.first else { return nil }
    let transformation = GraphTransformation(
        operation: .remove(.elements(firstScope)),
        yield: TransformationYield(
            structural: firstScope.maxBatch,
            value: 0,
            slack: .exact,
            estimatedProbes: firstScope.maxBatch
        ),
        precondition: .unconditional,
        postcondition: TransformationPostcondition(
            isStructural: true,
            invalidatesConvergence: [],
            enablesRemoval: []
        )
    )
    return TransformationScope(
        transformation: transformation,
        baseSequence: sequence,
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}
