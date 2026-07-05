//
//  RelationSearchTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Relation Search Tests

/// Pins the stall gate of ``RelationQuery`` and the probe protocol of ``GraphRelationEncoder``.
///
/// The workload shape is the RatioCoupling challenge: two leaves coupled by `x = 2y` with `x >= 20`, which no other joint move preserves (see `difference-family-query-floor.md`). Every gate and probe assertion runs for both an unsigned tag (bit pattern equals value) and a signed tag (XOR sign-magnitude encoding, bit pattern is the sign-bit mask plus the value): the first shipped version of the query computed the ratio on raw bit patterns and silently never fired on signed integers, which is exactly what the real challenge generates.
@Suite("Relation search")
struct RelationSearchTests {
    private static let integerTags: [TypeTag] = [.uint64, .int64]

    // MARK: - Query Gate

    @Test("Query pairs stall-converged leaves with a small ratio", arguments: integerTags)
    func queryPairsStallConvergedLeaves(tag: TypeTag) throws {
        var graph = leafPairGraph(values: [200, 100], tag: tag)
        markStallConverged(&graph)

        let scope = try #require(RelationQuery.build(graph: graph))
        #expect(scope.pairs.count == 1)
        let pair = try #require(scope.pairs.first)
        #expect(pair.numerator == 2)
        #expect(pair.denominator == 1)
        #expect(pair.scale == 100)
    }

    @Test("Query stays closed without stall records", arguments: integerTags)
    func queryStaysClosedWithoutRecords(tag: TypeTag) {
        let graph = leafPairGraph(values: [200, 100], tag: tag)

        #expect(RelationQuery.build(graph: graph) == nil)
    }

    @Test("Query excludes equal values and oversized ratios", arguments: integerTags)
    func queryExcludesEqualValuesAndOversizedRatios(tag: TypeTag) {
        // Equal magnitudes reduce to 1:1, which lockstep's common-delta search already covers.
        var equalGraph = leafPairGraph(values: [100, 100], tag: tag)
        markStallConverged(&equalGraph)
        #expect(RelationQuery.build(graph: equalGraph) == nil)

        // 170:10 reduces to 17:1, above the ratio cap of 16.
        var oversizedGraph = leafPairGraph(values: [170, 10], tag: tag)
        markStallConverged(&oversizedGraph)
        #expect(RelationQuery.build(graph: oversizedGraph) == nil)
    }

    // MARK: - Encoder Probes

    @Test("Encoder probes the line minimum first", arguments: integerTags)
    func encoderProbesLineMinimumFirst(tag: TypeTag) throws {
        var graph = leafPairGraph(values: [200, 100], tag: tag)
        markStallConverged(&graph)
        let scope = try #require(relationInput(graph: graph))

        var encoder = GraphRelationEncoder()
        encoder.start(scope: scope)

        var candidateBuffer = scope.baseSequence
        let firstProbe = encoder.nextProbe(into: &candidateBuffer, lastAccepted: false)
        #expect(firstProbe != nil)

        #expect(semanticMagnitudes(of: candidateBuffer) == [2, 1])
    }

    @Test("Encoder converges to the smallest accepted scale factor", arguments: integerTags)
    func encoderConvergesToSmallestAcceptedScale(tag: TypeTag) throws {
        var graph = leafPairGraph(values: [200, 100], tag: tag)
        markStallConverged(&graph)
        let scope = try #require(relationInput(graph: graph))

        var encoder = GraphRelationEncoder()
        encoder.start(scope: scope)

        // The RatioCoupling oracle: still failing iff x >= 20 and x == 2y. Candidates hold the ratio by construction, so acceptance is x >= 20.
        var candidateBuffer = scope.baseSequence
        var lastAccepted = false
        var bestAccepted: [UInt64] = []
        var probeCount = 0
        while encoder.nextProbe(into: &candidateBuffer, lastAccepted: lastAccepted) != nil {
            probeCount += 1
            let magnitudes = semanticMagnitudes(of: candidateBuffer)
            lastAccepted = magnitudes.count == 2 && magnitudes[0] >= 20 && magnitudes[0] == 2 * magnitudes[1]
            if lastAccepted {
                bestAccepted = magnitudes
            }
        }

        #expect(bestAccepted == [20, 10])
        #expect(probeCount <= 12, "Binary search over scale 1...99 should stay within log bounds")
    }

    @Test("Encoder terminates when every probe is rejected", arguments: integerTags)
    func encoderTerminatesOnAllRejections(tag: TypeTag) throws {
        var graph = leafPairGraph(values: [200, 100], tag: tag)
        markStallConverged(&graph)
        let scope = try #require(relationInput(graph: graph))

        var encoder = GraphRelationEncoder()
        encoder.start(scope: scope)

        var candidateBuffer = scope.baseSequence
        var probeCount = 0
        while encoder.nextProbe(into: &candidateBuffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(probeCount > 0)
        #expect(probeCount <= 12, "A wrong relation inference must cost at most a direct shot plus a short binary search")
    }
}

// MARK: - Test helpers

private func leafPairGraph(values: [UInt64], tag: TypeTag) -> ChoiceGraph {
    let elements = values.map { value in
        ChoiceTree.choice(
            ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern(forMagnitude: value, tag: tag)), tag: tag),
            .init(validRange: nil, isRangeExplicit: false)
        )
    }
    return ChoiceGraph.build(from: .group(elements))
}

private func bitPattern(forMagnitude magnitude: UInt64, tag: TypeTag) -> UInt64 {
    let anyValueOfTag = ChoiceValue(tag.makeConvertible(bitPattern64: 0), tag: tag)
    return anyValueOfTag.semanticSimplest.bitPattern64 &+ magnitude
}

private func semanticMagnitudes(of sequence: ChoiceSequence) -> [UInt64] {
    sequence.compactMap { entry in
        guard let value = entry.value else {
            return nil
        }
        return value.choice.bitPattern64 &- value.choice.semanticSimplest.bitPattern64
    }
}

private func markStallConverged(_ graph: inout ChoiceGraph) {
    for nodeID in graph.leafNodes {
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
            continue
        }
        graph.convergenceStore[nodeID] = ConvergedOrigin(
            bound: metadata.value.bitPattern64,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
    }
}

private func relationInput(graph: ChoiceGraph) -> EncoderInput? {
    guard let scope = RelationQuery.build(graph: graph) else {
        return nil
    }
    let tree = rebuildTree(graph: graph)
    return EncoderInput(
        transformation: GraphTransformation(
            operation: .exchange(.relation(scope)),
            priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
        ),
        baseSequence: ChoiceSequence.flatten(tree),
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}

private func rebuildTree(graph: ChoiceGraph) -> ChoiceTree {
    let elements = graph.leafNodes.compactMap { nodeID -> ChoiceTree? in
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
            return nil
        }
        return .choice(metadata.value, .init(validRange: metadata.validRange, isRangeExplicit: metadata.isRangeExplicit))
    }
    return .group(elements)
}
