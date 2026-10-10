import Testing
@testable import ExhaustCore

@Suite("Symmetric sequence removal")
struct SymmetricRemovalTests {
    @Test("Both edges are removed atomically and grow inward", arguments: [7, 8])
    func inwardGrowth(count: Int) throws {
        let values = Array(UInt64(1) ... UInt64(count))
        var observed: [[UInt64]] = []
        var fixture = try SymmetricFixture(values: values) { array in
            observed.append(array)
            return array.count < 2
        }
        let report = try fixture.run()

        let acceptedPairs = (count - 2) / 2
        let expectedProbes = (1 ... acceptedPairs + 1).map { pairs in
            Array(values[pairs ..< count - pairs])
        }
        let lastAccepted = Array(values[acceptedPairs ..< count - acceptedPairs])
        #expect(observed == expectedProbes)
        #expect(fixture.state.output as? [UInt64] == lastAccepted)
        #expect(report.counts.accepted == acceptedPairs)
        #expect(report.probeCount == acceptedPairs + 1)
        #expect(report.anyRequiresRebuild)
        #expect(ChoiceSequence(fixture.state.tree) == fixture.state.sequence)
    }

    @Test("A pair can accept when deleting either edge alone rejects")
    func coupledEdges() throws {
        let values: [UInt64] = [1, 2, 3, 2, 1]
        let property: ([UInt64]) -> Bool = { array in
            guard Set(array).count >= 2, array.count.isMultiple(of: 2) == false else { return true }
            return array.elementsEqual(array.reversed()) == false
        }
        #expect(property(Array(values.dropFirst())))
        #expect(property(Array(values.dropLast())))
        var fixture = try SymmetricFixture(values: values, property: property)
        let report = try fixture.run()

        #expect(fixture.state.output as? [UInt64] == [2, 3, 2])
        #expect(report.counts.accepted == 1)
        #expect(report.probeCount == 2)
    }

    @Test("A rejected edge pair stops symmetric growth")
    func rejectedSeedStopsGrowth() throws {
        let values = Array(UInt64(1) ... 8)
        var observed: [[UInt64]] = []
        var fixture = try SymmetricFixture(values: values) { array in
            observed.append(array)
            return array.count != values.count
        }
        let report = try fixture.run()

        #expect(observed == [[2, 3, 4, 5, 6, 7]])
        #expect(fixture.state.output as? [UInt64] == values)
        #expect(report.counts.accepted == 0)
        #expect(report.probeCount == 1)
    }

    @Test("Minimum length truncates both arms equally", arguments: [7, 8])
    func constrainedGrowth(count: Int) throws {
        let values = Array(UInt64(1) ... UInt64(count))
        var observed: [[UInt64]] = []
        var fixture = try SymmetricFixture(values: values, minimum: 3) { array in
            observed.append(array)
            return false
        }
        let report = try fixture.run()

        #expect(observed == [Array(values[1 ..< count - 1]), Array(values[2 ..< count - 2])])
        #expect(fixture.state.output as? [UInt64] == Array(values[2 ..< count - 2]))
        #expect(report.counts.accepted == 2)
        #expect(report.probeCount == 2)
    }

    @Test("Exponential growth narrows to the largest accepted edge pair count")
    func binarySearchAfterRejection() throws {
        let values = Array(UInt64(1) ... 20)
        var observed: [[UInt64]] = []
        var fixture = try SymmetricFixture(values: values, minimum: 2) { array in
            observed.append(array)
            return array.count < 8
        }
        let report = try fixture.run()

        #expect(observed.map(\.count) == [18, 16, 14, 12, 4, 8, 6])
        #expect(observed.allSatisfy { array in
            let removedPerEdge = (values.count - array.count) / 2
            return array == Array(values[removedPerEdge ..< values.count - removedPerEdge])
        })
        #expect(fixture.state.output as? [UInt64] == Array(UInt64(7) ... 14))
        #expect(report.counts.accepted == 5)
        #expect(report.probeCount == 7)
    }

    @Test("Small and fixed-length sequences only get legal symmetric seeds", arguments: [0, 1, 2, 3, 4])
    func smallSequences(count: Int) throws {
        let values = (0 ..< count).map(UInt64.init)
        for minimum in 0 ... count {
            let fixture = try SymmetricFixture(values: values, minimum: minimum) { _ in false }
            let transformations = fixture.symmetricCandidates
            let canSeed = count - minimum >= 2
            #expect(transformations.count == (canSeed ? 1 : 0))
            if let transformation = transformations.first {
                let scope = try #require(windowScope(of: transformation))
                let initialNodeIDs = try #require(scope.removalNodeIDs(step: 1))
                #expect(initialNodeIDs == [scope.elementNodeIDs[0], scope.elementNodeIDs[scope.elementNodeIDs.count - 1]])
                #expect(scope.elementNodeIDs.count <= count - minimum)
                #expect(scope.elementNodeIDs.count.isMultiple(of: 2))
                #expect(Set(scope.elementNodeIDs).count == scope.elementNodeIDs.count)
                #expect(scope.removalNodeIDs(step: 0) == nil)
                #expect(scope.removalNodeIDs(step: Int.max) == nil)
                let expectedYield = initialNodeIDs.reduce(0) { total, nodeID in
                    total + (fixture.state.graph.nodes[nodeID].positionRange?.count ?? 0)
                }
                #expect(transformation.priority.structuralBenefit == expectedYield)
            }
        }
    }

    @Test("Rejected emptying and centered growth do not suppress symmetric growth")
    func rejectionCacheSeparatesGrowth() throws {
        let fixture = try SymmetricFixture(values: Array(UInt64(1) ... 8)) { _ in true }
        let graph = fixture.state.graph
        let scopes = RemovalQuery.elementRemovalScopes(graph: graph)
        let emptying = try #require(CandidateSourceBuilder.buildEmptyingCandidates(graph: graph, elementScopes: scopes).first)
        let centered = try #require(CandidateSourceBuilder.buildCenteredCandidates(graph: graph, elementScopes: scopes).first)
        let symmetric = try #require(fixture.symmetricCandidates.first)
        var cache = CandidateRejectionCache()
        cache.recordRejection(operation: emptying.operation, sequence: fixture.state.sequence, graph: graph)
        cache.recordRejection(operation: centered.operation, sequence: fixture.state.sequence, graph: graph)

        #expect(cache.isRejected(operation: emptying.operation, sequence: fixture.state.sequence, graph: graph))
        #expect(cache.isRejected(operation: centered.operation, sequence: fixture.state.sequence, graph: graph))
        #expect(cache.isRejected(operation: symmetric.operation, sequence: fixture.state.sequence, graph: graph) == false)
        cache.recordRejection(operation: symmetric.operation, sequence: fixture.state.sequence, graph: graph)
        #expect(cache.isRejected(operation: symmetric.operation, sequence: fixture.state.sequence, graph: graph))
    }

    @Test("Symmetric growth removes complete nested sequence elements")
    func compositeElements() throws {
        let element = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 20), within: 2 ... 2)
        let generator = Gen.arrayOf(element, within: 0 ... 6)
        let values: [[UInt64]] = [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10], [11, 12]]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let graph = ChoiceGraph.build(from: tree)
        let transformations = CandidateSourceBuilder.buildSymmetricCandidates(
            graph: graph,
            elementScopes: RemovalQuery.elementRemovalScopes(graph: graph)
        )
        #expect(transformations.count == 1)
        let transformation = try #require(transformations.first)
        var observed: [[[UInt64]]] = []
        var state = ProbeSessionFixtureState(
            sequence: ChoiceSequence(tree),
            tree: tree,
            output: values,
            graph: graph,
            gen: generator.erase(),
            property: { output in
                let array = output as! [[UInt64]]
                observed.append(array)
                return array.count < 2
            }
        )
        let session = state.makeSession(for: EncoderInput(
            transformation: transformation,
            baseSequence: state.sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        ))
        let report = session.runToCompletion(state: &state)

        #expect(observed == [Array(values[1 ..< 5]), Array(values[2 ..< 4]), []])
        #expect(state.output as? [[UInt64]] == Array(values[2 ..< 4]))
        #expect(report.counts.accepted == 2)
        #expect(report.probeCount == 3)
        #expect(ChoiceSequence(state.tree) == state.sequence)
    }
}

private func windowScope(of transformation: GraphTransformation) -> WindowRemovalScope? {
    guard case let .remove(.window(scope)) = transformation.operation else { return nil }
    return scope
}

private struct SymmetricFixture {
    var state: ProbeSessionFixtureState

    init(values: [UInt64], minimum: Int = 0, property: @escaping ([UInt64]) -> Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 20), within: UInt64(minimum) ... UInt64(values.count))
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let graph = ChoiceGraph.build(from: tree)
        state = ProbeSessionFixtureState(
            sequence: ChoiceSequence(tree),
            tree: tree,
            output: values,
            graph: graph,
            gen: generator.erase(),
            property: { property($0 as! [UInt64]) }
        )
    }

    var symmetricCandidates: [GraphTransformation] {
        CandidateSourceBuilder.buildSymmetricCandidates(
            graph: state.graph,
            elementScopes: RemovalQuery.elementRemovalScopes(graph: state.graph)
        )
    }

    mutating func run() throws -> PassReport {
        let transformation = try #require(symmetricCandidates.first)
        let session = state.makeSession(for: EncoderInput(
            transformation: transformation,
            baseSequence: state.sequence,
            tree: state.tree,
            graph: state.graph,
            warmStartRecords: [:]
        ))
        return session.runToCompletion(state: &state)
    }
}
