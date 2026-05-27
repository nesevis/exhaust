import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Lane-collapse encoder")
struct LaneCollapseEncoderTests {
    @Test("Zeroes lane markers and moves elements to prefix region")
    func zerosAndReorders() throws {
        let gen = laneTaggedArrayGen(concurrencyLevel: 2)
        // 3 concurrent (lanes 1, 2) and 2 prefix (lane 0), interleaved
        let value: [(UInt8, UInt64)] = [
            (1, 10),
            (0, 20),
            (2, 30),
            (0, 40),
            (1, 50),
        ]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        // Property fails when at least 2 elements are on concurrent lanes
        let property: ([(UInt8, UInt64)]) -> Bool = { pairs in
            pairs.count(where: { $0.0 != 0 }) < 2
        }
        #expect(property(value) == false)

        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: [.laneCollapse]
        )

        let result = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
        )

        let reduced = result.1
        let laneMarkers = reduced.map(\.0)
        let nonPrefixCount = laneMarkers.count(where: { $0 != 0 })

        // The encoder should have collapsed exactly one concurrent element to prefix,
        // leaving exactly 2 non-prefix (the minimum the property requires)
        #expect(nonPrefixCount == 2, "Exactly 2 non-prefix elements should remain (property minimum): got \(laneMarkers)")

        // All prefix elements must be contiguous at the front — no prefix element after a non-prefix
        let firstNonPrefixIndex = laneMarkers.firstIndex(where: { $0 != 0 }) ?? laneMarkers.count
        let allPrefixAtFront = laneMarkers.prefix(firstNonPrefixIndex).allSatisfy { $0 == 0 }
        let noPrefixAfter = laneMarkers.suffix(from: firstNonPrefixIndex).allSatisfy { $0 != 0 }
        #expect(allPrefixAtFront, "All prefix elements must be at the front: \(laneMarkers)")
        #expect(noPrefixAfter, "No prefix elements after the first non-prefix: \(laneMarkers)")

        // Total element count is unchanged — lane collapse does not delete
        #expect(reduced.count == value.count, "Lane collapse should not change the element count")

        // Values are unchanged — lane collapse does not modify command arguments
        let reducedValues = Set(reduced.map(\.1))
        let originalValues = Set(value.map(\.1))
        #expect(reducedValues == originalValues, "Values should be preserved: \(reduced.map(\.1))")
    }

    @Test("Returns nil when all elements are already prefix")
    func allPrefixIsNoOp() throws {
        let gen = laneTaggedArrayGen(concurrencyLevel: 2)
        let value: [(UInt8, UInt64)] = [(0, 10), (0, 20), (0, 30)]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: [.laneCollapse]
        )

        let result = try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config) { _ in false }
        #expect(result == nil, "Reducer should return nil when nothing can be improved")
    }

    @Test("Prefix elements are contiguous at the front after reduction with 3 lanes")
    func prefixContiguity() throws {
        let gen = laneTaggedArrayGen(concurrencyLevel: 3)
        // All 6 elements on concurrent lanes, no initial prefix
        let value: [(UInt8, UInt64)] = [
            (2, 10),
            (1, 20),
            (3, 30),
            (3, 40),
            (1, 50),
            (2, 60),
        ]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        // Property fails when at least 2 elements are non-prefix
        let property: ([(UInt8, UInt64)]) -> Bool = { pairs in
            pairs.count(where: { $0.0 != 0 }) < 2
        }

        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: [.laneCollapse]
        )

        // Verify the reflected value round-trips correctly before reducing
        let prefix = ChoiceSequence.flatten(tree)
        if case let .success(roundTripped, _, _) = Materializer.materialize(gen, prefix: prefix, mode: .exact, fallbackTree: tree, materializePicks: true) {
            #expect(roundTripped.count == value.count, "Reflected value should round-trip: got \(roundTripped.map(\.0))")
        }

        let result = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
        )

        let laneMarkers = result.1.map(\.0)
        let nonPrefixCount = laneMarkers.count(where: { $0 != 0 })
        let prefixCount = laneMarkers.count(where: { $0 == 0 })

        #expect(nonPrefixCount == 2, "Exactly 2 non-prefix elements should remain: \(laneMarkers)")
        #expect(prefixCount == 4, "4 elements should have been collapsed to prefix: \(laneMarkers)")

        // Strict contiguity: prefix region is [0, ..., 0], then non-prefix region is [X, ..., X]
        let firstNonPrefixIndex = laneMarkers.firstIndex(where: { $0 != 0 }) ?? laneMarkers.count
        #expect(firstNonPrefixIndex == prefixCount, "Prefix region ends at index \(prefixCount): \(laneMarkers)")
        let noPrefixInTail = laneMarkers.suffix(from: firstNonPrefixIndex).contains(where: { $0 == 0 }) == false
        #expect(noPrefixInTail, "No prefix elements in the concurrent tail: \(laneMarkers)")
    }

    @Test("Encoder finds all leaves after partition moves elements")
    func leavesRebuildAfterReorder() throws {
        let gen = laneTaggedArrayGen(concurrencyLevel: 3)
        // Interleaved: concurrent, concurrent, prefix, concurrent.
        // When the first concurrent is zeroed, the partition moves the existing
        // prefix element forward, displacing stale leaf positions.
        let value: [(UInt8, UInt64)] = [
            (1, 10),
            (2, 20),
            (0, 30),
            (3, 40),
        ]
        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let minimizationScope = LaneCollapseQuery.build(graph: graph) else {
            Issue.record("No lane-collapse scope")
            return
        }
        let transformation = GraphTransformation(
            operation: .minimize(minimizationScope),
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 10
            )
        )
        let scope = EncoderInput(
            transformation: transformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )

        var encoder = GraphLaneCollapseEncoder()
        encoder.start(scope: scope)

        var candidate = sequence
        var acceptedCount = 0
        while encoder.nextProbe(into: &candidate, lastAccepted: acceptedCount > 0) != nil {
            acceptedCount += 1
        }

        #expect(
            acceptedCount == 3,
            "Encoder should probe all 3 non-zero lanes in a single pass, got \(acceptedCount)"
        )
    }

    @Test("Graph tags laneControl leaves correctly")
    func graphTagsLaneControlLeaves() throws {
        let gen = laneTaggedArrayGen(concurrencyLevel: 2)
        let value: [(UInt8, UInt64)] = [(1, 10), (2, 20)]
        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let graph = ChoiceGraph.build(from: tree)

        let laneControlNodes = graph.liveNodeIDs.filter { graph.nodes[$0].scopeAnnotation.isLaneControl }
        #expect(laneControlNodes.count == 2, "Should find 2 laneControl nodes, found \(laneControlNodes.count)")

        for nodeID in laneControlNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else {
                Issue.record("laneControl node \(nodeID) is not chooseBits")
                continue
            }
            #expect(metadata.typeTag == .laneControl, "Tag should be .laneControl")
            #expect(metadata.value.bitPattern64 != 0, "Value should be non-zero")
        }
    }
}

// MARK: - Helpers

/// Builds a generator that produces arrays of `(laneMarker: UInt8, value: UInt64)` tuples where the lane marker uses `.laneControl` tag.
private func laneTaggedArrayGen(concurrencyLevel: UInt8) -> Generator<[(UInt8, UInt64)]> {
    let laneGen: Generator<UInt8> = {
        let operation = ReflectiveOperation.chooseBits(
            min: 0,
            max: UInt64(concurrencyLevel),
            tag: .laneControl,
            isRangeExplicit: true
        )
        return .impure(operation: operation) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                fatalError("unexpected result type")
            }
            return .pure(UInt8(convertible.bitPattern64))
        }
    }()

    let valueGen = Gen.choose(in: UInt64(0) ... 100)
    let pairGen = Gen.zip(laneGen, valueGen)
    return Gen.arrayOf(pairGen, within: 1 ... 10)
}
