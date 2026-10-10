import Testing
@testable import ExhaustCore

@Suite("Centered sequence removal")
struct CenteredRemovalTests {
    @Test("Even sequences start with the middle pair and grow on both sides")
    func evenGrowth() throws {
        let values = Array(UInt64(1) ... 8)
        var observed: [[UInt64]] = []
        var fixture = try CenteredFixture(values: values) { array in
            observed.append(array)
            return array.first != 1 || array.last != 8
        }
        let report = try fixture.run()

        #expect(observed == [
            [1, 2, 3, 6, 7, 8],
            [1, 2, 7, 8],
            [1, 8],
            [],
        ])
        #expect(fixture.state.output as? [UInt64] == [1, 8])
        #expect(report.counts.accepted == 3)
        #expect(report.probeCount == 4)
        #expect(report.anyRequiresRebuild)
        #expect(ChoiceSequence(fixture.state.tree) == fixture.state.sequence)
    }

    @Test("Odd sequences start with the middle element and grow on both sides")
    func oddGrowth() throws {
        var observed: [[UInt64]] = []
        var fixture = try CenteredFixture(values: Array(UInt64(1) ... 7)) { array in
            observed.append(array)
            return array.first != 1 || array.last != 7
        }
        let report = try fixture.run()

        #expect(observed == [
            [1, 2, 3, 5, 6, 7],
            [1, 2, 6, 7],
            [1, 7],
            [],
        ])
        #expect(fixture.state.output as? [UInt64] == [1, 7])
        #expect(report.counts.accepted == 3)
        #expect(report.probeCount == 4)
    }

    @Test("A rejected middle pair stops outward growth")
    func rejectedSeedStopsGrowth() throws {
        let values = Array(UInt64(1) ... 8)
        var observed: [[UInt64]] = []
        var fixture = try CenteredFixture(values: values) { array in
            observed.append(array)
            return array.count != values.count
        }
        let report = try fixture.run()

        #expect(observed == [[1, 2, 3, 6, 7, 8]])
        #expect(fixture.state.output as? [UInt64] == values)
        #expect(report.counts.accepted == 0)
        #expect(report.probeCount == 1)
    }

    @Test("Minimum lengths preserve the original midpoint and parity", arguments: [7, 8])
    func constrainedGrowth(count: Int) throws {
        let values = Array(UInt64(1) ... UInt64(count))
        var observed: [[UInt64]] = []
        var fixture = try CenteredFixture(values: values, minimum: 3) { array in
            observed.append(array)
            return false
        }
        let report = try fixture.run()

        let firstRemovalCount = count.isMultiple(of: 2) ? 2 : 1
        let firstStart = (count - firstRemovalCount) / 2
        #expect(observed == [
            Array(values[..<firstStart]) + Array(values[(firstStart + firstRemovalCount)...]),
            Array(values.prefix(2)) + Array(values.suffix(2)),
        ])
        #expect(fixture.state.output as? [UInt64] == Array(values.prefix(2)) + Array(values.suffix(2)))
        #expect(report.counts.accepted == 2)
        #expect(report.probeCount == 2)
    }

    @Test("Exponential growth narrows to the largest accepted symmetric window")
    func binarySearchAfterRejection() throws {
        let values = Array(UInt64(1) ... 20)
        var observed: [[UInt64]] = []
        var fixture = try CenteredFixture(values: values, minimum: 2) { array in
            observed.append(array)
            return array.count < 8
        }
        let report = try fixture.run()

        #expect(observed.map(\.count) == [18, 16, 14, 12, 4, 8, 6])
        #expect(observed.allSatisfy { array in
            let retained = array.count / 2
            return array == Array(values.prefix(retained)) + Array(values.suffix(retained))
        })
        #expect(fixture.state.output as? [UInt64] == [1, 2, 3, 4, 17, 18, 19, 20])
        #expect(report.counts.accepted == 5)
        #expect(report.probeCount == 7)
    }

    @Test("Small and fixed-length sequences only get legal middle seeds", arguments: [0, 1, 2, 3, 4])
    func smallSequences(count: Int) throws {
        let values = (0 ..< count).map(UInt64.init)
        for minimum in 0 ... count {
            let fixture = try CenteredFixture(values: values, minimum: minimum) { _ in false }
            let transformations = fixture.centeredCandidates
            let seedCount = count.isMultiple(of: 2) ? 2 : 1
            let canSeed = count > 0 && count - minimum >= seedCount
            #expect(transformations.count == (canSeed ? 1 : 0))
            if let transformation = transformations.first {
                let scope = try #require(windowScope(of: transformation))
                let initialNodeIDs = try #require(scope.removalNodeIDs(step: 1))
                #expect(initialNodeIDs.count == seedCount)
                #expect(scope.elementNodeIDs.count <= count - minimum)
                #expect(scope.elementNodeIDs.count % 2 == count % 2)
                #expect(scope.removalNodeIDs(step: Int.max) == nil)
                let expectedYield = initialNodeIDs.reduce(0) { total, nodeID in
                    total + (fixture.state.graph.nodes[nodeID].positionRange?.count ?? 0)
                }
                #expect(transformation.priority.structuralBenefit == expectedYield)
            }
        }
    }

    @Test("Rejecting full emptying does not suppress the middle search")
    func rejectionCacheSeparatesGrowth() throws {
        let fixture = try CenteredFixture(values: Array(UInt64(1) ... 8)) { _ in true }
        let graph = fixture.state.graph
        let scopes = RemovalQuery.elementRemovalScopes(graph: graph)
        let emptying = try #require(CandidateSourceBuilder.buildEmptyingCandidates(graph: graph, elementScopes: scopes).first)
        let centered = try #require(fixture.centeredCandidates.first)
        let scope = try #require(windowScope(of: centered))
        let rightward = GraphOperation.remove(.window(WindowRemovalScope(
            sequenceNodeID: scope.sequenceNodeID,
            elementNodeIDs: scope.elementNodeIDs
        )))
        var cache = CandidateRejectionCache()
        cache.recordRejection(operation: emptying.operation, sequence: fixture.state.sequence, graph: graph)
        cache.recordRejection(operation: rightward, sequence: fixture.state.sequence, graph: graph)

        #expect(cache.isRejected(operation: emptying.operation, sequence: fixture.state.sequence, graph: graph))
        #expect(cache.isRejected(operation: centered.operation, sequence: fixture.state.sequence, graph: graph) == false)
        cache.recordRejection(operation: centered.operation, sequence: fixture.state.sequence, graph: graph)
        #expect(cache.isRejected(operation: centered.operation, sequence: fixture.state.sequence, graph: graph))
    }

    @Test("The default deletion scheduler grows the center while preserving both ends")
    func defaultReducerUsesCenter() throws {
        let values = Array(UInt64(1) ... 8)
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 20), within: 0 ... 8)
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var observed: [[UInt64]] = []
        let result = try Interpreters.choiceGraphReduce(
            gen: generator,
            tree: tree,
            config: .init(maxStalls: 2, enabledEncoders: [.deletion])
        ) { array in
            observed.append(array)
            return array.first != 1 || array.last != 8
        }
        let (_, output) = try #require(result.counterexample)

        #expect(output == [1, 8])
        #expect(observed.contains([1, 2, 3, 6, 7, 8]))
        #expect(observed.contains([1, 2, 7, 8]))
    }

    @Test("Middle growth removes complete composite elements")
    func compositeElements() throws {
        let element = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 20), within: 2 ... 2)
        let generator = Gen.arrayOf(element, within: 0 ... 6)
        let values: [[UInt64]] = [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10], [11, 12]]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let graph = ChoiceGraph.build(from: tree)
        let transformations = CandidateSourceBuilder.buildCenteredCandidates(
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
                return array.first != values.first || array.last != values.last
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

        #expect(observed == [
            [values[0], values[1], values[4], values[5]],
            [values[0], values[5]],
            [],
        ])
        #expect(state.output as? [[UInt64]] == [values[0], values[5]])
        #expect(report.counts.accepted == 2)
        #expect(report.probeCount == 3)
        #expect(ChoiceSequence(state.tree) == state.sequence)
    }
}

private func windowScope(of transformation: GraphTransformation) -> WindowRemovalScope? {
    guard case let .remove(.window(scope)) = transformation.operation else { return nil }
    return scope
}

private struct CenteredFixture {
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

    var centeredCandidates: [GraphTransformation] {
        CandidateSourceBuilder.buildCenteredCandidates(
            graph: state.graph,
            elementScopes: RemovalQuery.elementRemovalScopes(graph: state.graph)
        )
    }

    mutating func run() throws -> PassReport {
        let transformation = try #require(centeredCandidates.first)
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
