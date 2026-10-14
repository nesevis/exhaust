import Testing
@testable import ExhaustCore

@Suite("Scoped source parity")
struct ScopedSourceParityTests {
    @Test(
        "Scoped family sources dispatch the registered encoders' scopes in the legacy value sources' order and priority",
        arguments: [false, true]
    )
    func dispatchOrderMatchesLegacy(deferBindInner: Bool) throws {
        for graph in try Self.graphs() {
            let legacy = Self.drainLegacy(graph: graph, deferBindInner: deferBindInner)
            let scoped = Self.drainScoped(graph: graph, deferBindInner: deferBindInner)

            #expect(scoped == legacy)
        }
    }

    @Test(
        "Scoped structural families dispatch the legacy structural sources' scopes in their order and priority",
        arguments: [false, true]
    )
    func structuralDispatchOrderMatchesLegacy(comparesWithPreviousGraph: Bool) throws {
        for graph in try Self.structuralGraphs() {
            let previousGraph = comparesWithPreviousGraph ? graph : nil
            let legacy = Self.drainLegacyStructural(graph: graph, previousGraph: previousGraph)
            let scoped = Self.drainScopedStructural(graph: graph, previousGraph: previousGraph)

            #expect(scoped == legacy)
        }
    }

    @Test("Scoped structural families carry the legacy sources' scheduling and invalidation metadata")
    func structuralMetadataMatchesLegacy() throws {
        for graph in try Self.structuralGraphs() {
            let legacy = CandidateSourceBuilder.buildStructuralSources(from: graph).map { source in
                SourceMetadata(
                    prefersInitialDispatch: source.prefersInitialDispatch,
                    isValueDependent: source.isValueDependent,
                    isPermutationSource: source.isPermutationSource,
                    canReuseAfterLeafKindChange: source.canReuseAfterLeafKindChange,
                    priority: source.peekPriority
                )
            }
            var sources = ScopedSource.prepareStructuralSources(from: graph, tuning: ScopedReductionTuning())
            let scoped = sources.indices.map { index in
                SourceMetadata(
                    prefersInitialDispatch: sources[index].prefersInitialDispatch,
                    isValueDependent: sources[index].isValueDependent,
                    isPermutationSource: sources[index].isPermutationSource,
                    canReuseAfterLeafKindChange: sources[index].canReuseAfterLeafKindChange,
                    priority: sources[index].dispatchPriority
                )
            }

            #expect(scoped == legacy)
        }
    }

    @Test(
        "The replacement family's merged-row path emits the legacy stream in both orders",
        arguments: [true, false]
    )
    func replacementHeapPathMatchesLegacy(inPriorityOrder: Bool) throws {
        for graph in try Self.structuralGraphs() {
            var legacySource = ReplacementCandidateSource(graph: graph, order: inPriorityOrder ? .priority : .discovery, eagerRowLimit: 0)
            var scopedSource = ScopedReplacementSource(graph: graph, order: inPriorityOrder ? .priority : .discovery, eagerRowLimit: 0)
            var legacy: [Dispatched] = []
            while let transformation = legacySource.next() {
                legacy.append(Dispatched(Self.opportunity(for: transformation.operation), priority: transformation.priority))
            }
            var scoped: [Dispatched] = []
            while let priced = scopedSource.nextScope() {
                scoped.append(Dispatched(priced.opportunity, priority: priced.priority))
            }

            #expect(scoped == legacy)
        }
    }

    @Test("The numeric reorder family offers the final pass's reordering scope")
    func reorderFamilyMatchesFinalPass() throws {
        for graph in try Self.structuralGraphs() {
            var source = ScopedSource.prepareReorderSource(from: graph, tuning: ScopedReductionTuning())
            let scoped = source?.nextScope().map { Dispatched($0.opportunity, priority: $0.priority) }
            let legacy = ReorderingQuery.build(graph: graph).map { reorderScope in
                Dispatched(.reorder(reorderScope), priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1))
            }

            #expect(scoped == legacy)
        }
    }

    @Test("The graphs offer every registered encoder at least one scope")
    func graphsCoverEveryEncoder() throws {
        let stalled = try StagedJointFixture(StagedJointCase.all[0])
        var stagedJoint = ScopedSource.prepareStagedJointSource(
            from: stalled.graph,
            sequence: stalled.sequence,
            deferBindInner: false,
            isFruitlessBind: { _ in false },
            exhausted: nil,
            tuning: ScopedReductionTuning()
        )
        // Staged joint offers scopes only over stalled leaves, which none of the value family graphs have.
        let stagedJointKinds = stagedJoint.nextScope().map { priced in
            [priced.opportunity.encoder(tuning: ScopedReductionTuning()).name]
        } ?? []
        // Numeric reorder runs only in the final pass, so its family is prepared separately too.
        let reorderKinds = try Self.structuralGraphs().compactMap { graph in
            var source = ScopedSource.prepareReorderSource(from: graph, tuning: ScopedReductionTuning())
            return source?.nextScope().map { priced in priced.opportunity.encoder(tuning: ScopedReductionTuning()).name }
        }
        let valueKinds = try Self.graphs().flatMap { graph in
            Self.drainScoped(graph: graph, deferBindInner: false).map(\.encoderName)
        }
        let structuralKinds = try Self.structuralGraphs().flatMap { graph in
            Self.drainScopedStructural(graph: graph, previousGraph: nil).map(\.encoderName)
        }
        let kinds = valueKinds + structuralKinds + stagedJointKinds + reorderKinds

        for encoder in ScopedEncoderKind.registered(tuning: ScopedReductionTuning()) {
            #expect(kinds.contains(encoder.name))
        }
    }
}

// MARK: - Helpers

extension ScopedSourceParityTests {
    /// What dispatch selects, reduced to values both reducers can be compared on.
    struct Dispatched: Equatable {
        let encoderName: EncoderName
        let nodeIDs: [Int]
        let priority: DispatchPriority
    }

    /// Scheduling and invalidation metadata one prepared source exposes.
    struct SourceMetadata: Equatable {
        let prefersInitialDispatch: Bool
        let isValueDependent: Bool
        let isPermutationSource: Bool
        let canReuseAfterLeafKindChange: Bool
        let priority: DispatchPriority?
    }

    /// The value family graphs, plus one graph of each structural fixture shape.
    static func structuralGraphs() throws -> [ChoiceGraph] {
        let structuralCases = StructuralCase.all.filter { structuralCase in structuralCase.label.hasSuffix("always fails") }
        return try Self.graphs() + structuralCases.map { try StructuralFixture($0).graph } + [Self.boundSequenceGraph()]
    }

    /// Sequences inside and under binds, so migration's dependency checks rule out pairs in both directions.
    static func boundSequenceGraph() -> ChoiceGraph {
        let binds = (0 ..< 3).map { index in
            ChoiceTree.bind(
                fingerprint: UInt64(100 + index),
                inner: .uint64Sequence([1, 2]),
                bound: .uint64Sequence(Array(repeating: 1, count: index + 1))
            )
        }
        return ChoiceGraph.build(from: .group(binds + [.uint64Sequence([3]), .uint64Sequence([4, 5]), .uint64Sequence([])]))
    }

    static func graphs() throws -> [ChoiceGraph] {
        try BoundValueCase.all.map { try BoundValueFixture($0).graph }
            + ExchangeCase.all.map { try ScopedExchangeFixture($0).graph }
            + PivotProperty.allCases.map { try PivotParityFixture(property: $0).graph }
            + [DepthCollapseFixture(failingCount: 0).graph]
            + LaneCase.all.map { try LaneCollapseFixture($0).graph }
            + ValueCase.all.map { try ValueSearchFixture($0).graph }
            + RedistributionCase.all.map { try RedistributionFixture($0).graph }
            + LockstepCase.all.map { try LockstepFixture($0).graph }
            + RelationCase.all.map { try RelationFixture($0).graph }
    }

    /// Drains today's value sources as ``DispatchLoop`` selects from them, keeping the registered encoders' scopes.
    static func drainLegacy(graph: ChoiceGraph, deferBindInner: Bool) -> [Dispatched] {
        var sources = CandidateSourceBuilder.buildValueSources(from: graph, deferBindInner: deferBindInner)
        var dispatched: [Dispatched] = []
        while let index = ChoiceGraphScheduler.highestPrioritySourceIndex(sources) {
            guard let transformation = sources[index].next() else {
                sources.swapAt(index, sources.count - 1)
                sources.removeLast()
                continue
            }
            let opportunity: ScopedOpportunity? = switch transformation.operation {
                case let .minimize(.boundValue(bindScope)):
                    .boundValue(bindScope)
                case let .minimize(.bindPivot(pivotScope)):
                    .bindPivot(pivotScope)
                case let .exchange(.boundExchange(exchange)):
                    .boundExchange(exchange)
                case let .exchange(.redistribution(redistributionScope)):
                    .redistribution(redistributionScope)
                case let .exchange(.tandem(tandemScope)):
                    .lockstep(tandemScope)
                case let .exchange(.relation(relationScope)):
                    .relation(relationScope)
                case let .minimize(.depthCollapse(depthScope)):
                    .depthCollapse(depthScope)
                case let .minimize(.laneCollapse(laneScope)):
                    .laneCollapse(laneScope)
                case let .minimize(.valueLeaves(integerScope)):
                    .valueSearch(.integer(integerScope))
                case let .minimize(.floatLeaves(floatScope)):
                    .valueSearch(.float(floatScope))
                default:
                    nil
            }
            if let opportunity {
                dispatched.append(Dispatched(opportunity, priority: transformation.priority))
            }
        }
        return dispatched
    }

    /// Drains today's structural sources as ``DispatchLoop`` selects from them.
    static func drainLegacyStructural(graph: ChoiceGraph, previousGraph: ChoiceGraph?) -> [Dispatched] {
        var sources = CandidateSourceBuilder.buildStructuralSources(from: graph, previousGraph: previousGraph)
        var dispatched: [Dispatched] = []
        while let index = ChoiceGraphScheduler.highestPrioritySourceIndex(sources) {
            guard let transformation = sources[index].next() else {
                sources.swapAt(index, sources.count - 1)
                sources.removeLast()
                continue
            }
            let opportunity: ScopedOpportunity? = Self.structuralOpportunity(for: transformation.operation)
            if let opportunity {
                dispatched.append(Dispatched(opportunity, priority: transformation.priority))
            }
        }
        return dispatched
    }

    /// Drains the scoped structural families the same way.
    static func drainScopedStructural(graph: ChoiceGraph, previousGraph: ChoiceGraph?) -> [Dispatched] {
        var sources = ScopedSource.prepareStructuralSources(
            from: graph,
            previousGraph: previousGraph,
            tuning: ScopedReductionTuning()
        )
        var dispatched: [Dispatched] = []
        while let index = ScopedSource.highestPrioritySourceIndex(&sources) {
            guard let priced = sources[index].nextScope() else {
                sources.swapAt(index, sources.count - 1)
                sources.removeLast()
                continue
            }
            dispatched.append(Dispatched(priced.opportunity, priority: priced.priority))
        }
        return dispatched
    }

    /// The scoped opportunity a structural operation maps to, or nil for any other operation.
    static func structuralOpportunity(for operation: GraphOperation) -> ScopedOpportunity? {
        switch operation {
            case let .remove(.elements(elementScope)):
                .removal(.elements(elementScope))
            case let .remove(.coveringAligned(alignedScope)):
                .removal(.coveringAligned(alignedScope))
            case let .remove(.window(windowScope)):
                .removal(.window(windowScope))
            case let .replace(.selfSimilar(targetNodeID, donorNodeID, _)):
                .substitution(.selfSimilar(targetNodeID: targetNodeID, donorNodeID: donorNodeID))
            case let .replace(.descendantPromotion(ancestorPickNodeID, descendantPickNodeID, _)):
                .substitution(.descendantPromotion(ancestorPickNodeID: ancestorPickNodeID, descendantPickNodeID: descendantPickNodeID))
            case let .replace(.branchPivot(pickNodeID, targetBranchID)):
                .branchPivot(ScopedBranchPivotEncoder.Scope(pickNodeID: pickNodeID, targetBranchID: targetBranchID))
            case let .migrate(migrationScope):
                .migration(migrationScope)
            case let .permute(permutationScope):
                .swap(permutationScope)
            default:
                nil
        }
    }

    /// Maps a replacement operation; every operation a replacement source emits has a structural opportunity.
    static func opportunity(for operation: GraphOperation) -> ScopedOpportunity {
        guard let opportunity = structuralOpportunity(for: operation) else {
            preconditionFailure("A replacement source emitted \(operation.encoderName)")
        }
        return opportunity
    }

    /// Drains the scoped family sources the same way.
    static func drainScoped(graph: ChoiceGraph, deferBindInner: Bool) -> [Dispatched] {
        var sources = ScopedSource.prepareValueSources(
            from: graph,
            deferBindInner: deferBindInner,
            tuning: ScopedReductionTuning()
        )
        var dispatched: [Dispatched] = []
        while let index = ScopedSource.highestPrioritySourceIndex(&sources) {
            guard let priced = sources[index].nextScope() else {
                sources.swapAt(index, sources.count - 1)
                sources.removeLast()
                continue
            }
            dispatched.append(Dispatched(priced.opportunity, priority: priced.priority))
        }
        return dispatched
    }
}

extension ScopedSourceParityTests.Dispatched {
    init(_ opportunity: ScopedOpportunity, priority: DispatchPriority) {
        encoderName = opportunity.encoder(tuning: ScopedReductionTuning()).name
        nodeIDs = switch opportunity {
            case let .boundValue(bindScope):
                [bindScope.bindNodeID, bindScope.upstreamLeafNodeID]
            case let .bindPivot(pivotScope):
                [pivotScope.bindNodeID, pivotScope.pickNodeID, Int(truncatingIfNeeded: pivotScope.targetBranchID)]
            case let .boundExchange(exchange):
                [exchange.sourceLeafNodeID, exchange.sinkLeafNodeID]
            case let .depthCollapse(depthScope):
                depthScope.leaves.map(\.nodeID)
            case let .laneCollapse(laneScope):
                laneScope.leaves.map(\.nodeID)
            case let .valueSearch(.integer(integerScope)):
                integerScope.leaves.map(\.nodeID)
            case let .valueSearch(.float(floatScope)):
                floatScope.leaves.map(\.nodeID)
            case let .redistribution(redistributionScope):
                redistributionScope.pairs.flatMap { pair in [pair.source.nodeID, pair.sink.nodeID] }
            case let .lockstep(tandemScope):
                tandemScope.groups.flatMap { group in group.leaves.map(\.nodeID) }
            case let .relation(relationScope):
                relationScope.pairs.flatMap { pair in [pair.first.nodeID, pair.second.nodeID] }
            case let .stagedJoint(checkpoint):
                checkpoint.pairs.flatMap { pair in [pair.source.nodeID, pair.sink.nodeID] }
            case let .removal(.elements(elementScope)):
                elementScope.targets.flatMap { target in [target.sequenceNodeID] + target.elementNodeIDs } + [elementScope.maxBatch, elementScope.maxElementYield]
            case let .removal(.coveringAligned(alignedScope)):
                alignedScope.siblings.flatMap { sibling in [sibling.sequenceNodeID] + sibling.elementNodeIDs } + alignedScope.skipValues.map { Int($0) }
            case let .removal(.window(windowScope)):
                [windowScope.sequenceNodeID] + windowScope.elementNodeIDs + [Self.growthCode(windowScope.growth)]
            case let .substitution(.selfSimilar(targetNodeID, donorNodeID)):
                [0, targetNodeID, donorNodeID]
            case let .substitution(.descendantPromotion(ancestorPickNodeID, descendantPickNodeID)):
                [1, ancestorPickNodeID, descendantPickNodeID]
            case let .branchPivot(pivotScope):
                [pivotScope.pickNodeID, Int(truncatingIfNeeded: pivotScope.targetBranchID)]
            case let .migration(migrationScope):
                [migrationScope.sourceSequenceNodeID, migrationScope.receiverSequenceNodeID] + migrationScope.elementNodeIDs
            case let .swap(permutationScope):
                [permutationScope.parentNodeID] + permutationScope.swappableGroups.flatMap(\.self)
            case let .reorder(reorderScope):
                reorderScope.groups.flatMap { group in [group.depth] + group.ranges.flatMap { range in [range.lowerBound, range.upperBound] } }
        }
        self.priority = priority
    }

    private static func growthCode(_ growth: WindowRemovalScope.Growth) -> Int {
        switch growth {
            case .rightward:
                0
            case .outward:
                1
            case .symmetric:
                2
        }
    }
}
