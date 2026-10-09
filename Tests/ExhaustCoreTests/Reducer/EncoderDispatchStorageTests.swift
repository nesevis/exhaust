import Testing
@testable import ExhaustCore

/// Pins storage reuse and independent search progress across copied dispatch handles.
@Suite("Encoder dispatch storage")
struct EncoderDispatchStorageTests {
    @Test("Existential construction selects storage for every concrete encoder")
    func existentialConstruction() throws {
        try expectConcreteStorage(GraphStructuralEncoder())
        try expectConcreteStorage(GraphValueEncoder())
        try expectConcreteStorage(GraphRedistributionEncoder())
        try expectConcreteStorage(GraphLockstepEncoder())
        try expectConcreteStorage(GraphRelationEncoder())
        try expectConcreteStorage(StagedJointEncoder())
        try expectConcreteStorage(GraphSwapEncoder())
        try expectConcreteStorage(GraphWindowRemovalEncoder())
        try expectConcreteStorage(GraphReorderEncoder())
        try expectConcreteStorage(GraphLaneCollapseEncoder())
        try expectConcreteStorage(GraphDepthCollapseEncoder())
        try expectConcreteStorage(GraphBinarySearchEncoder())
        try expectConcreteStorage(GraphBoundValueCoveringEncoder())
        try expectConcreteStorage(GraphLiftedStageEncoder(name: .composed, mutation: .leafValues([])))
        try expectConcreteStorage(GraphComposedEncoder(
            name: .composed,
            makeProposals: { _ in nil },
            lift: { _, _ in nil }
        ))
    }

    @Test("Constructing from an erased dispatch preserves its existing storage")
    func dispatchConstructionPreservesStorage() throws {
        let encoder = EncoderDispatch(GraphBinarySearchEncoder())
        let erased: any GraphEncoder = encoder
        let reconstructed = EncoderDispatch(erased)
        #expect(try storageIdentity(of: reconstructed) == storageIdentity(of: encoder))
    }

    @Test("Refreshing a uniquely owned stateful encoder preserves its box")
    func refreshReusesStorage() throws {
        let scope = try scope(value: 100)
        let encoders: [any GraphEncoder] = [
            GraphSwapEncoder(),
            GraphComposedEncoder(name: .composed, makeProposals: { _ in nil }, lift: { _, _ in nil }),
        ]
        for concrete in encoders {
            var encoder = EncoderDispatch(concrete)
            encoder.start(scope: scope)
            let initialIdentity = try storageIdentity(of: encoder)
            encoder.refreshState(graph: scope.graph, sequence: scope.baseSequence)
            #expect(try storageIdentity(of: encoder) == initialIdentity)
        }
    }

    @Test("A uniquely owned dispatch reuses its box across starts and probes")
    func uniqueStorageIsReused() throws {
        let scope = try scope(value: 100)
        var encoder = EncoderDispatch(GraphBinarySearchEncoder())
        let initialIdentity = try storageIdentity(of: encoder)
        encoder.start(scope: scope)
        #expect(try storageIdentity(of: encoder) == initialIdentity)

        var candidate = scope.baseSequence
        for _ in 0 ..< 3 {
            _ = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
            #expect(try storageIdentity(of: encoder) == initialIdentity)
        }
        encoder.start(scope: scope)
        #expect(try storageIdentity(of: encoder) == initialIdentity)
    }

    @Test("Copied dispatches advance independently after sharing a search prefix")
    func copiedProgressIsIndependent() throws {
        let scope = try scope(value: 100)
        var encoder = EncoderDispatch(GraphBinarySearchEncoder())
        var reference = GraphBinarySearchEncoder()
        encoder.start(scope: scope)
        reference.start(scope: scope)
        var candidate = scope.baseSequence
        var expected = scope.baseSequence
        _ = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
        _ = try #require(reference.nextProbe(into: &expected, lastAccepted: false))
        var snapshot = encoder

        for _ in 0 ..< 3 {
            _ = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
        }
        var snapshotCandidate = scope.baseSequence
        _ = try #require(snapshot.nextProbe(into: &snapshotCandidate, lastAccepted: false))
        _ = try #require(reference.nextProbe(into: &expected, lastAccepted: false))
        #expect(snapshotCandidate == expected)
        #expect(snapshotCandidate != candidate)
        #expect(try storageIdentity(of: snapshot) != storageIdentity(of: encoder))
    }

    @Test("Restarting a copied dispatch preserves the original search")
    func restartingCopyIsIndependent() throws {
        let originalScope = try scope(value: 100)
        let restartedScope = try scope(value: 200)
        var encoder = EncoderDispatch(GraphBinarySearchEncoder())
        var reference = GraphBinarySearchEncoder()
        encoder.start(scope: originalScope)
        reference.start(scope: originalScope)
        var candidate = originalScope.baseSequence
        var expected = originalScope.baseSequence
        _ = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
        _ = try #require(reference.nextProbe(into: &expected, lastAccepted: false))
        var snapshot = encoder
        snapshot.start(scope: restartedScope)

        _ = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
        _ = try #require(reference.nextProbe(into: &expected, lastAccepted: false))
        #expect(candidate == expected)
        var restartedCandidate = restartedScope.baseSequence
        _ = try #require(snapshot.nextProbe(into: &restartedCandidate, lastAccepted: false))
        #expect(restartedCandidate != candidate)
    }

    /// Checks the erased input's dynamic type without reproducing the initializer's case mapping.
    private func expectConcreteStorage<Encoder: GraphEncoder>(_ encoder: Encoder) throws {
        let erased: any GraphEncoder = encoder
        let dispatch = EncoderDispatch(erased)
        let payload = try #require(Mirror(reflecting: dispatch).children.first?.value)
        let storage = try #require(payload as? EncoderStorage<Encoder>)
        #expect(storage.value.name == encoder.name)
        #expect(dispatch.name == encoder.name)
    }

    /// Reads the pointer-sized tagged handle without retaining its box, which would force detachment on the next mutation.
    private func storageIdentity(of encoder: borrowing EncoderDispatch) throws -> UInt {
        try #require(MemoryLayout<EncoderDispatch>.size == MemoryLayout<UInt>.size)
        return withUnsafeBytes(of: encoder) { $0.load(as: UInt.self) }
    }

    /// Provides a single-leaf search with enough rejected probes to distinguish independent cursors.
    private func scope(value: UInt64) throws -> EncoderInput {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 1000, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let minimization = try #require(MinimizationQuery.build(graph: graph).first)
        return EncoderInput(
            transformation: .init(operation: .minimize(minimization), priority: .zeroBenefit),
            baseSequence: ChoiceSequence(tree),
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
    }
}
