import Testing
@testable import ExhaustCore

@Suite("Interior window removal")
struct WindowRemovalTests {
    @Test("Batch removal emits interior window seeds at the halving-grid offsets after halving finishes")
    func seedsFollowHalving() throws {
        let fixture = try WindowFixture(values: [1, 2, 2, 2, 2, 2, 2, 1])
        var source = BatchRemovalSource(sequenceNodeID: fixture.sequenceNodeID, graph: fixture.graph)

        var operations: [GraphOperation] = []
        while let transformation = source.next() {
            operations.append(transformation.operation)
        }
        let windows = operations.compactMap(windowScope(of:))
        let firstWindowIndex = try #require(operations.firstIndex { windowScope(of: $0) != nil })

        #expect(operations[firstWindowIndex...].count == windows.count)
        #expect(windows.map(\.elementNodeIDs) == [
            Array(fixture.elementNodeIDs[4 ..< 8]),
            Array(fixture.elementNodeIDs[2 ..< 8]),
            Array(fixture.elementNodeIDs[1 ..< 8]),
        ])
    }

    @Test("An accepted window keeps growing until removing more would make the property pass")
    func windowGrowsAcrossAcceptances() throws {
        var fixture = try WindowFixture(values: [1, 2, 2, 2, 2, 2, 2, 1]) { value in
            guard let array = value as? [UInt64] else {
                return true
            }
            return (array.first == 1 && array.last == 1) == false
        }
        let report = try fixture.runWindow(startingAt: 4)

        #expect(fixture.state.output as? [UInt64] == [1, 2, 2, 2, 1])
        #expect(report.counts.accepted == 3)
        #expect(report.probeCount == 4)
        #expect(report.anyRequiresRebuild)
    }

    @Test("A proposed length beyond the window's capacity ends growth without a probe")
    func lengthBeyondCapacityIsRejected() throws {
        var fixture = try WindowFixture(values: [1, 2, 2, 1]) { _ in false }
        let report = try fixture.runWindow(startingAt: 2)

        #expect(fixture.state.output as? [UInt64] == [1, 2])
        #expect(report.probeCount == 2)
    }
}

// MARK: - Fixtures

private func windowScope(of operation: GraphOperation) -> WindowRemovalScope? {
    guard case let .remove(.window(scope)) = operation else {
        return nil
    }
    return scope
}

private struct WindowFixture {
    var state: ProbeSessionFixtureState
    let graph: ChoiceGraph
    let sequenceNodeID: Int
    let elementNodeIDs: [Int]

    init(values: [UInt64], property: @escaping (Any) -> Bool = { _ in true }) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 3), within: 0 ... 8)
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let graph = ChoiceGraph.build(from: tree)
        let sequenceNodeID = try #require(graph.liveNodeIDs.first { nodeID in
            guard case .sequence = graph.nodes[nodeID].kind else {
                return false
            }
            return true
        })
        self.graph = graph
        self.sequenceNodeID = sequenceNodeID
        elementNodeIDs = graph.nodes[sequenceNodeID].children.sorted { lhs, rhs in
            (graph.nodes[lhs].positionRange?.lowerBound ?? 0) < (graph.nodes[rhs].positionRange?.lowerBound ?? 0)
        }
        state = ProbeSessionFixtureState(
            sequence: ChoiceSequence(tree),
            tree: tree,
            output: values,
            graph: graph,
            gen: generator.erase(),
            property: property
        )
    }

    /// Runs one probe session for a window that starts at `offset` and may extend to the end of the sequence.
    mutating func runWindow(startingAt offset: Int) throws -> PassReport {
        let transformation = GraphTransformation(
            operation: .remove(.window(WindowRemovalScope(
                sequenceNodeID: sequenceNodeID,
                elementNodeIDs: Array(elementNodeIDs[offset...])
            ))),
            priority: .zeroBenefit
        )
        var session = state.makeSession(for: EncoderInput(
            transformation: transformation,
            baseSequence: state.sequence,
            tree: state.tree,
            graph: graph,
            warmStartRecords: [:]
        ))
        return session.runToCompletion(state: &state)
    }
}
