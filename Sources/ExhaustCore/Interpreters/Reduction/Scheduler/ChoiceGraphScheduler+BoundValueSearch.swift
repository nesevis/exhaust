//
//  ChoiceGraphScheduler+BoundValueSearch.swift
//  Exhaust
//

// MARK: - Bound Value Composition Construction

extension ChoiceGraphScheduler {
    /// Probes one controller candidate's downstream search emits before a nested-bind composition moves on to the next candidate. Paused searches resume in later turns, so one controller tuple cannot consume the root's total cap.
    private static let probesPerControllerCandidateTurn = 2

    /// Downstream builds one dispatch of a nested bind chain of three or fewer stages may spend across all its stages, counting failed builds and builds whose search emits nothing. Each build materializes the generator, and nesting multiplies them, so the chain root owns one pool for the whole chain. Two nested controllers over 12 and 41 values need more than 64 builds to reach a tail value inside the range. Longer chains get more; see ``nestedChainBuildPool(chainLength:)``.
    static let nestedChainBaseBuildPool = 128

    /// Upper bound on ``nestedChainBuildPool(chainLength:)``, whatever the chain's length.
    static let nestedChainMaxBuildPool = 1024

    /// Builds a chain of `chainLength` stages may spend: ``nestedChainBaseBuildPool`` for three or fewer stages, quadrupled for each stage beyond that, and at most ``nestedChainMaxBuildPool``. A fixed pool spread over more stages leaves each controller fewer candidates, and at five stages 128 builds allow fewer than three per controller, too few for a move that lowers two controllers while raising a third.
    static func nestedChainBuildPool(chainLength: Int) -> Int {
        var pool = nestedChainBaseBuildPool
        var length = 3
        while length < chainLength, pool < nestedChainMaxBuildPool {
            pool *= 4
            length += 1
        }
        return min(pool, nestedChainMaxBuildPool)
    }

    /// Builds the chain root may spend per start. Deeper stages get less; see ``nestedChainBuildsPerStart(depth:)``.
    static let nestedChainRootBuildsPerStart = 64

    /// Builds a stage at nesting depth *d* may spend per start: ``nestedChainRootBuildsPerStart`` scaled by (3/4)^*d*, and at least one. Shallow controllers get more breadth, and no single deep stage can drain the shared pool.
    static func nestedChainBuildsPerStart(depth: Int) -> Int {
        var builds = nestedChainRootBuildsPerStart
        var level = 0
        while level < depth {
            builds = builds * 3 / 4
            level += 1
        }
        return max(builds, 1)
    }

    /// Builds a ``GraphComposedEncoder`` for a bound value scope.
    ///
    /// A single bind uses ``GraphBinarySearchEncoder`` upstream and terminates in binary or covering value search. A bound subtree containing exactly one nested bind from an unseen bind site uses ``GraphSingleLeafDomainEncoder`` and recursively builds another composition, allowing controllers at different depths to compensate in opposite directions. Repeated fingerprints mark recursive generator expansion and terminate composition before work grows with the generated recursion depth.
    ///
    /// Each downstream build materializes the upstream candidate through `gen`, locates the bind again by path and fingerprint in the fresh graph, and either descends into the next unseen bind or constructs a terminal search over ordinary leaves.
    ///
    /// - Parameters:
    ///   - bindScope: The bound value scope from the source pipeline.
    ///   - scope: The dispatched ``EncoderInput``. Used to seed the upstream encoder's one-leaf scope and to provide the parent tree as the lift's fallback.
    ///   - gen: The generator. Captured by the lift closure for materialization.
    ///   - upstreamBudget: Maximum number of upstream probes the composition will explore. Decayed by ``ChoiceGraphScheduler/runCore(gen:initialTree:initialOutput:config:collectStats:property:)`` based on per-bind stall counts.
    ///   - totalProbeCap: Maximum probes the composition emits across all lifts, zero meaning uncapped. The machine passes ``SchedulerTuning/composedFirstDispatchProbeCap`` for a bind fingerprint's first dispatch of the run and zero afterwards.
    static func makeBoundValueComposition(
        bindScope: BoundValueScope,
        scope: EncoderInput,
        graph: ChoiceGraph,
        gen: AnyGenerator,
        upstreamBudget: Int = 15,
        totalProbeCap: Int = 0,
        buildTally: BoundValueBuildTally = BoundValueBuildTally()
    ) -> EncoderDispatch {
        // Synthesize the upstream scope: a one-leaf integer minimization on the bind-inner. ``mayReshapeOnAcceptance`` is false here because the composition synthesizes the reshape change in ``GraphComposedEncoder/wrap``
        // when wrapping each downstream probe — the upstream encoder produces a pure value-only mutation and the composition flips ``mayReshape`` on its way out.
        let upstreamLeafEntry = LeafEntry(
            nodeID: bindScope.upstreamLeafNodeID,
            mayReshapeOnAcceptance: false
        )
        let upstreamScope = EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(ValueMinimizationScope(
                    leaves: [upstreamLeafEntry],
                    batchZeroEligible: false
                ))),
                priority: scope.transformation.priority
            ),
            baseSequence: scope.baseSequence,
            tree: scope.tree,
            graph: scope.graph,
            warmStartRecords: [:]
        )
        var seenBindFingerprints: Set<UInt64> = []
        if bindScope.bindNodeID < graph.nodes.count,
           case let .bind(metadata) = graph.nodes[bindScope.bindNodeID].kind
        {
            seenBindFingerprints.insert(metadata.fingerprint)
        }
        let chainLength = composableChainLength(
            from: bindScope.bindNodeID,
            graph: graph,
            seenBindFingerprints: seenBindFingerprints
        )
        return .composed(makeBoundValueCompositionEncoder(
            bindNodeID: bindScope.bindNodeID,
            controllerLeafNodeID: bindScope.upstreamLeafNodeID,
            upstreamScope: upstreamScope,
            stage: chainLength > 1 ? .chainRoot : .single,
            chain: BoundValueChain(
                gen: gen,
                upstreamBudget: upstreamBudget,
                rootSequenceCount: scope.baseSequence.count,
                seenBindFingerprints: seenBindFingerprints,
                buildTally: buildTally,
                depth: 0,
                buildPool: CompositionBuildPool(capacity: nestedChainBuildPool(chainLength: chainLength))
            ),
            totalProbeCap: totalProbeCap
        ))
    }

    /// Builds a ``GraphBindPivotEncoder`` whose lift materializes through `gen` in guided mode.
    ///
    /// The encoder reads the bind, the pick, and the target branch from the dispatched scope on ``GraphEncoder/start(scope:)``; only the generator has to be captured here. Guided mode is what carries the previous bound subtree's leaf values across the pivot wherever their ranges still admit them, so the covering search starts from the closest assignment the generator can reproduce.
    static func makeBindPivotEncoder(gen: AnyGenerator) -> EncoderDispatch {
        .bindPivot(GraphBindPivotEncoder(lift: { candidate, fallbackTree in
            guard case let .success(_, freshTree, _) = Materializer.materializeAny(
                gen,
                context: .init(
                    prefix: candidate,
                    mode: .guided(seed: 0, fallbackTree: fallbackTree),
                    fallbackTree: fallbackTree,
                    materializePicks: true
                )
            ) else {
                return nil
            }
            return freshTree
        }))
    }

    /// Creates one composition stage. A stage with one composable nested bind builds another stage downstream; otherwise it terminates in value covering.
    private static func makeBoundValueCompositionEncoder(
        bindNodeID: Int,
        controllerLeafNodeID: Int,
        upstreamScope: EncoderInput,
        stage: BoundValueStage,
        chain: BoundValueChain,
        totalProbeCap: Int
    ) -> GraphComposedEncoder {
        let upstream: EncoderDispatch = stage.searchesWholeDomain
            ? .singleLeafDomain(GraphSingleLeafDomainEncoder(
                includesCurrent: stage.includesCurrentController
            ))
            : .binarySearch(GraphBinarySearchEncoder())
        return GraphComposedEncoder(
            name: .composed,
            upstream: upstream,
            upstreamScope: upstreamScope,
            upstreamBudget: chain.upstreamBudget,
            totalProbeCap: totalProbeCap,
            chainLimits: chainLimits(for: stage, chain: chain),
            downstreamBuilder: { upstreamCandidate, _, parent in
                buildBoundValueDownstream(
                    upstreamCandidate: upstreamCandidate,
                    parent: parent,
                    bindNodeID: bindNodeID,
                    controllerLeafNodeID: controllerLeafNodeID,
                    stage: stage,
                    chain: chain
                )
            }
        )
    }

    /// Stage turns and build limits for one stage's composition. Nil for a single bind, whose builds do not multiply.
    private static func chainLimits(
        for stage: BoundValueStage,
        chain: BoundValueChain
    ) -> NestedChainLimits? {
        switch stage {
            case .single:
                nil
            case .chainRoot, .chainInterior, .chainTail:
                NestedChainLimits(
                    probesPerStageTurn: probesPerControllerCandidateTurn,
                    maxBuildsPerStart: nestedChainBuildsPerStart(depth: chain.depth),
                    buildPool: chain.buildPool
                )
        }
    }

    /// Lifts one controller candidate, then builds either the next nested composition or the terminal bound-value search, recording how the build ended.
    private static func buildBoundValueDownstream(
        upstreamCandidate: ChoiceSequence,
        parent: EncoderInput,
        bindNodeID: Int,
        controllerLeafNodeID: Int,
        stage: BoundValueStage,
        chain: BoundValueChain
    ) -> (encoder: EncoderDispatch, scope: EncoderInput)? {
        let build = liftAndBuildDownstream(
            upstreamCandidate: upstreamCandidate,
            parent: parent,
            bindNodeID: bindNodeID,
            controllerLeafNodeID: controllerLeafNodeID,
            stage: stage,
            chain: chain
        )
        chain.buildTally.record(stage, build.outcome)
        return build.downstream
    }

    /// Runs the build's steps: lift, then a nested stage when the stage may recurse and the lifted bound subtree holds one composable nested bind, otherwise a terminal search.
    private static func liftAndBuildDownstream(
        upstreamCandidate: ChoiceSequence,
        parent: EncoderInput,
        bindNodeID: Int,
        controllerLeafNodeID: Int,
        stage: BoundValueStage,
        chain: BoundValueChain
    ) -> BoundValueBuild {
        // Read the proposed upstream value for instrumentation.
        let upstreamSeqIndex = parent.graph.nodes[controllerLeafNodeID].positionRange?.lowerBound
        let upstreamProposedBitPattern: UInt64? = upstreamSeqIndex.flatMap { i in
            i < upstreamCandidate.count
                ? upstreamCandidate[i].value?.choice.bitPattern64
                : nil
        }

        let lifted: LiftedBind
        switch liftBind(
            upstreamCandidate: upstreamCandidate,
            upstreamProposedBitPattern: upstreamProposedBitPattern,
            parent: parent,
            bindNodeID: bindNodeID,
            stage: stage,
            chain: chain
        ) {
            case let .lifted(liftedBind):
                lifted = liftedBind
            case let .failed(outcome):
                return BoundValueBuild(outcome: outcome)
        }

        if stage.canRecurseIntoNestedBind,
           let nestedBind = composableNestedBind(
               under: lifted.bindNodeID,
               graph: lifted.graph,
               seenBindFingerprints: chain.seenBindFingerprints
           )
        {
            return nestedStage(
                lifted: lifted,
                nestedBind: nestedBind,
                parent: parent,
                chain: chain
            )
        }
        return terminalStage(
            lifted: lifted,
            upstreamProposedBitPattern: upstreamProposedBitPattern,
            parent: parent,
            chain: chain
        )
    }

    /// Materializes the upstream candidate and locates the dispatched bind again in the lifted graph, by path and fingerprint.
    private static func liftBind(
        upstreamCandidate: ChoiceSequence,
        upstreamProposedBitPattern: UInt64?,
        parent: EncoderInput,
        bindNodeID: Int,
        stage: BoundValueStage,
        chain: BoundValueChain
    ) -> BoundValueLift {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)

        // 1. Materialize through the generator to get the new bound subtree. Use guided mode so that downstream coordinates outside the new range get re-resolved from the fallback tree (or PRNG when the fallback has no info) instead of being rejected. The upstream candidate carries the *previous* downstream values, which are typically out-of-range for the new upstream value (Coupling: dropping `n` from 2 to 1 makes the array element value `2`
        //    out-of-range for the new `int(in: 0...1)` element generator). Mirrors
        //    the bound-value composition's lift configuration.
        guard case let .success(_, freshTree, _) = Materializer.materializeAny(
            chain.gen,
            context: .init(
                prefix: upstreamCandidate,
                mode: .guided(seed: 0, fallbackTree: parent.tree),
                fallbackTree: parent.tree,
                materializePicks: true
            )
        ) else {
            Self.logReducer("bound_value_lift_failed", isInstrumented: isInstrumented, metadata: [
                "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
                "candidate_len": "\(upstreamCandidate.count)",
            ])
            return .failed(.materializationFailed)
        }

        let liftedSequence = ChoiceSequence(freshTree)
        // A stage that cannot recurse always ends in a terminal search, so a lift the terminal search would reject is dropped before the graph build.
        if stage.canRecurseIntoNestedBind == false,
           chain.admitsTerminalSearch(liftedSequenceCount: liftedSequence.count) == false
        {
            return .failed(.liftedTooLong)
        }
        let liftedGraph = ChoiceGraph.build(from: freshTree)

        guard bindNodeID < parent.graph.nodes.count,
              case let .bind(sourceMetadata) = parent.graph.nodes[bindNodeID].kind,
              let liftedBindNodeID = liftedGraph.liveNodeIDs.first(where: { nodeID in
                  guard case let .bind(metadata) = liftedGraph.nodes[nodeID].kind else {
                      return false
                  }
                  return metadata.fingerprint == sourceMetadata.fingerprint
                      && metadata.bindPath == sourceMetadata.bindPath
              }),
              case let .bind(metadata) = liftedGraph.nodes[liftedBindNodeID].kind,
              liftedGraph.nodes[liftedBindNodeID].children.count > metadata.boundChildIndex
        else {
            return .failed(.bindNotFound)
        }
        let boundChildID = liftedGraph.nodes[liftedBindNodeID].children[metadata.boundChildIndex]
        guard let boundRange = liftedGraph.nodes[boundChildID].positionRange else {
            return .failed(.bindNotFound)
        }
        return .lifted(LiftedBind(
            sequence: liftedSequence,
            tree: freshTree,
            graph: liftedGraph,
            bindNodeID: liftedBindNodeID,
            boundRange: boundRange
        ))
    }

    /// Builds the composition one bind deeper, whose controller is the nested bind's inner leaf.
    private static func nestedStage(
        lifted: LiftedBind,
        nestedBind: (nodeID: Int, metadata: BindMetadata),
        parent: EncoderInput,
        chain: BoundValueChain
    ) -> BoundValueBuild {
        let nestedControllerLeafNodeID = lifted.graph.nodes[nestedBind.nodeID].children[nestedBind.metadata.innerChildIndex]
        let nestedChain = chain.descending(into: nestedBind.metadata.fingerprint)
        let nestedInput = boundValueInput(
            controllerLeafNodeID: nestedControllerLeafNodeID,
            sequence: lifted.sequence,
            tree: lifted.tree,
            graph: lifted.graph,
            priority: parent.transformation.priority
        )
        let nestedHasDescendant = composableNestedBind(
            under: nestedBind.nodeID,
            graph: lifted.graph,
            seenBindFingerprints: nestedChain.seenBindFingerprints
        ) != nil
        let nestedEncoder = makeBoundValueCompositionEncoder(
            bindNodeID: nestedBind.nodeID,
            controllerLeafNodeID: nestedControllerLeafNodeID,
            upstreamScope: nestedInput,
            stage: nestedHasDescendant ? .chainInterior : .chainTail,
            chain: nestedChain,
            totalProbeCap: 0
        )
        return BoundValueBuild(
            outcome: .nestedStage,
            downstream: (.composed(nestedEncoder), nestedInput)
        )
    }

    /// Builds the value search over the lifted bound subtree's leaves: binary search for one leaf, covering for several.
    private static func terminalStage(
        lifted: LiftedBind,
        upstreamProposedBitPattern: UInt64?,
        parent: EncoderInput,
        chain: BoundValueChain
    ) -> BoundValueBuild {
        let liftedGraph = lifted.graph
        let boundLeaves = liftedGraph.leafNodes.filter { leafID in
            guard let range = liftedGraph.nodes[leafID].positionRange else { return false }
            if liftedGraph.nodes[leafID].scopeAnnotation.isDepthControl { return false }
            return lifted.boundRange.contains(range.lowerBound)
        }

        guard chain.admitsTerminalSearch(liftedSequenceCount: lifted.sequence.count) else {
            return BoundValueBuild(outcome: .liftedTooLong)
        }
        // Nested bind inners stay fixed when the bound subtree is not a single chain. Changing one without recursively rebuilding its descendants produces an exact candidate with stale structure.
        let freeLeaves = boundLeaves.filter {
            liftedGraph.nodes[$0].scopeAnnotation.isBindInner == false
        }
        let downstreamLeaves = freeLeaves.isEmpty ? boundLeaves : freeLeaves
        guard downstreamLeaves.isEmpty == false else {
            return BoundValueBuild(outcome: .noDownstreamLeaves)
        }

        let downstreamScope = EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(ValueMinimizationScope(
                    leaves: downstreamLeaves.map {
                        LeafEntry(nodeID: $0, mayReshapeOnAcceptance: false)
                    },
                    batchZeroEligible: downstreamLeaves.count > 1
                ))),
                priority: parent.transformation.priority
            ),
            baseSequence: lifted.sequence,
            tree: lifted.tree,
            graph: liftedGraph,
            warmStartRecords: [:]
        )
        let downstreamEncoder: EncoderDispatch = downstreamLeaves.count == 1
            ? .binarySearch(GraphBinarySearchEncoder())
            : .boundValueCovering(GraphBoundValueCoveringEncoder())

        Self.logReducer("bound_value_lift_built", isInstrumented: ExhaustLog.isEnabled(.debug, for: .reducer), metadata: [
            "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
            "parent_seq_len": "\(parent.baseSequence.count)",
            "lifted_seq_len": "\(lifted.sequence.count)",
            "downstream_leaves": "\(downstreamLeaves.count)",
            "bound_range": "\(lifted.boundRange.lowerBound)...\(lifted.boundRange.upperBound)",
        ])
        return BoundValueBuild(
            outcome: .terminalSearch,
            downstream: (downstreamEncoder, downstreamScope)
        )
    }

    /// Counts the stages a composition rooted at `bindNodeID` can build in `graph`: the root plus each nested bind ``composableNestedBind(under:graph:seenBindFingerprints:)`` descends into. The walk stops where composition stops, at a branching dependency or a repeated fingerprint.
    ///
    /// Measured against the current graph only. A lift that changes the shape beneath a controller can lengthen or shorten the chain the stages actually build.
    private static func composableChainLength(
        from bindNodeID: Int,
        graph: ChoiceGraph,
        seenBindFingerprints: Set<UInt64>
    ) -> Int {
        var length = 1
        var seen = seenBindFingerprints
        var current = bindNodeID
        while let nested = composableNestedBind(
            under: current,
            graph: graph,
            seenBindFingerprints: seen
        ) {
            seen.insert(nested.metadata.fingerprint)
            current = nested.nodeID
            length += 1
        }
        return length
    }

    /// Returns the sole nested bind when composition can descend without revisiting a bind site.
    ///
    /// A repeated fingerprint identifies another expansion of a recursive generator's bind. Treating that expansion as another composition dimension makes work grow with the generated value's recursion depth. Branching dependencies and recursive expansions instead retain their controllers for later scheduler passes.
    static func composableNestedBind(
        under bindNodeID: Int,
        graph: ChoiceGraph,
        seenBindFingerprints: Set<UInt64>
    ) -> (nodeID: Int, metadata: BindMetadata)? {
        let nestedBindNodeIDs = directNestedBindNodeIDs(
            under: bindNodeID,
            graph: graph
        )
        guard nestedBindNodeIDs.count == 1 else {
            return nil
        }
        let nestedBindNodeID = nestedBindNodeIDs[0]
        guard nestedBindNodeID < graph.nodes.count,
              case let .bind(metadata) = graph.nodes[nestedBindNodeID].kind,
              seenBindFingerprints.contains(metadata.fingerprint) == false
        else {
            return nil
        }
        return (nestedBindNodeID, metadata)
    }

    /// Returns the outermost active binds with a `chooseBits` controller directly beneath this bind's bound child. More than one is a branching dependency rather than a chain and is left to the existing fixed-inner terminal search.
    private static func directNestedBindNodeIDs(
        under bindNodeID: Int,
        graph: ChoiceGraph
    ) -> [Int] {
        guard bindNodeID < graph.nodes.count,
              case let .bind(metadata) = graph.nodes[bindNodeID].kind,
              graph.nodes[bindNodeID].children.count > metadata.boundChildIndex
        else {
            return []
        }

        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        var nestedBindNodeIDs: [Int] = []
        var stack = [boundChildID]
        while let nodeID = stack.popLast() {
            let node = graph.nodes[nodeID]
            guard node.positionRange != nil else {
                continue
            }
            if case let .bind(nestedMetadata) = node.kind,
               node.children.count > max(
                   nestedMetadata.innerChildIndex,
                   nestedMetadata.boundChildIndex
               )
            {
                let innerChildID = node.children[nestedMetadata.innerChildIndex]
                let nestedBoundChildID = node.children[nestedMetadata.boundChildIndex]
                if case .chooseBits = graph.nodes[innerChildID].kind,
                   graph.nodes[nestedBoundChildID].positionRange != nil
                {
                    nestedBindNodeIDs.append(nodeID)
                    continue
                }
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return nestedBindNodeIDs
    }

    /// Builds the synthetic minimization input that drives one composition stage's controller.
    private static func boundValueInput(
        controllerLeafNodeID: Int,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        graph: ChoiceGraph,
        priority: DispatchPriority
    ) -> EncoderInput {
        EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(ValueMinimizationScope(
                    leaves: [LeafEntry(
                        nodeID: controllerLeafNodeID,
                        mayReshapeOnAcceptance: false
                    )],
                    batchZeroEligible: false
                ))),
                priority: priority
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
    }
}
