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
    /// A single bind uses rejected binary-search midpoints upstream and terminates in binary or covering value search. A bound subtree containing exactly one nested bind from an unseen bind site uses ``LeafCandidates`` domain enumeration and recursively builds another composition, allowing controllers at different depths to compensate in opposite directions. Repeated fingerprints mark recursive generator expansion and terminate composition before work grows with the generated recursion depth.
    ///
    /// Each downstream build materializes the upstream candidate through `gen`, locates the bind again by path and fingerprint in the fresh graph, and either descends into the next unseen bind or constructs a terminal search over ordinary leaves.
    ///
    /// - Parameters:
    ///   - bindScope: The bound value scope from the source pipeline.
    ///   - scope: The dispatched ``EncoderInput``. Provides controller choice metadata and the parent tree as the lift's fallback.
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
            controllerSequenceIndex: graph.nodes.indices.contains(bindScope.upstreamLeafNodeID)
                ? graph.nodes[bindScope.upstreamLeafNodeID].positionRange?.lowerBound
                : nil,
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
        controllerSequenceIndex: Int?,
        stage: BoundValueStage,
        chain: BoundValueChain,
        totalProbeCap: Int
    ) -> GraphComposedEncoder {
        let generator = chain.gen
        let buildTally = chain.buildTally
        return GraphComposedEncoder(
            name: .composed,
            makeProposals: { scope in
                guard scope.graph.nodes.indices.contains(controllerLeafNodeID),
                      case let .chooseBits(metadata) = scope.graph.nodes[controllerLeafNodeID].kind
                else {
                    return nil
                }
                guard stage.searchesWholeDomain == false || metadata.typeTag.isFloatingPoint == false else {
                    return nil
                }
                let current = metadata.value.bitPattern64
                let target = metadata.value.reductionTarget(in: metadata.validRange)
                let candidates = stage.searchesWholeDomain
                    ? LeafCandidates.candidates(
                        in: metadata.validRange ?? metadata.typeTag.bitPatternRange,
                        current: current,
                        target: target,
                        includesCurrent: stage.includesCurrentController
                    )
                    : LeafCandidates.rejectedBinarySearch(current: current, target: target)
                guard let cursor = LeafProposalCursor(
                    scope: scope,
                    leafNodeID: controllerLeafNodeID,
                    candidates: candidates
                ) else {
                    return nil
                }
                return .leaf(cursor)
            },
            policy: CompositionPolicy(
                stageBudget: chain.upstreamBudget,
                totalProbeCap: totalProbeCap,
                chainLimits: chainLimits(for: stage, chain: chain)
            ),
            lift: { candidate, fallbackTree in
                guard let tree = Materializer.guidedLift(
                    generator: generator,
                    prefix: candidate,
                    fallbackTree: fallbackTree
                ) else {
                    let proposed = controllerBitPattern(in: candidate, at: controllerSequenceIndex)
                    Self.logReducer("bound_value_lift_failed", isInstrumented: ExhaustLog.isEnabled(.debug, for: .reducer), metadata: [
                        "upstream_bp": proposed.map { "\($0)" } ?? "nil",
                        "candidate_len": "\(candidate.count)",
                    ])
                    return nil
                }
                return tree
            },
            recordLiftAttempt: { buildTally.recordAttempt() },
            recordBuild: { buildTally.record(stage, build: $0) },
            downstreamFactory: { proposal, lifted, parent in
                buildBoundValueDownstream(
                    upstreamCandidate: proposal.prefix,
                    liftResult: lifted,
                    parent: parent,
                    bindNodeID: bindNodeID,
                    controllerLeafNodeID: controllerLeafNodeID,
                    stage: stage,
                    chain: chain
                )
            }
        )
    }

    /// Reads logging metadata only when the controller position fits the proposed prefix.
    private static func controllerBitPattern(in sequence: ChoiceSequence, at index: Int?) -> UInt64? {
        index.flatMap { sequenceIndex in
            sequenceIndex < sequence.count ? sequence[sequenceIndex].value?.choice.bitPattern64 : nil
        }
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

    /// Builds a nested stage when the freshly lifted bound subtree holds one composable nested bind and the stage may recurse; otherwise builds the terminal search. Admission remains root-relative.
    private static func buildBoundValueDownstream(
        upstreamCandidate: ChoiceSequence,
        liftResult: LiftResult,
        parent: EncoderInput,
        bindNodeID: Int,
        controllerLeafNodeID: Int,
        stage: BoundValueStage,
        chain: BoundValueChain
    ) -> DownstreamBuild {
        // Read the proposed upstream value for instrumentation.
        let upstreamSequenceIndex = parent.graph.nodes[controllerLeafNodeID].positionRange?.lowerBound
        let upstreamProposedBitPattern = controllerBitPattern(in: upstreamCandidate, at: upstreamSequenceIndex)

        let lifted: LiftedBind
        switch locateLiftedBind(
            liftResult: liftResult,
            parent: parent,
            bindNodeID: bindNodeID,
            stage: stage,
            chain: chain
        ) {
            case let .lifted(liftedBind):
                lifted = liftedBind
            case let .failed(outcome):
                return .failed(outcome)
        }

        if stage.canRecurseIntoNestedBind,
           let nestedBind = lifted.graph.composableNestedBind(
               under: lifted.bindNodeID,
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

    /// Locates the dispatched bind in the lifted graph, rejecting terminal-only growth before paying for graph construction.
    private static func locateLiftedBind(
        liftResult: LiftResult,
        parent: EncoderInput,
        bindNodeID: Int,
        stage: BoundValueStage,
        chain: BoundValueChain
    ) -> BoundValueLift {
        let freshTree = liftResult.tree
        let liftedSequence = liftResult.sequence
        // A stage that cannot recurse always ends in a terminal search, so a lift the terminal search would reject is dropped before the graph build.
        if stage.canRecurseIntoNestedBind == false,
           chain.admitsTerminalSearch(liftedSequenceCount: liftedSequence.count) == false
        {
            return .failed(.liftedTooLong)
        }
        let liftedGraph = ChoiceGraph.build(from: freshTree)

        guard bindNodeID < parent.graph.nodes.count,
              case let .bind(sourceMetadata) = parent.graph.nodes[bindNodeID].kind,
              let liftedBindNodeID = liftedGraph.bindNodeID(
                  fingerprint: sourceMetadata.fingerprint,
                  path: sourceMetadata.bindPath
              ),
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
    ) -> DownstreamBuild {
        let nestedControllerLeafNodeID = lifted.graph.nodes[nestedBind.nodeID].children[nestedBind.metadata.innerChildIndex]
        let nestedChain = chain.descending(into: nestedBind.metadata.fingerprint)
        let nestedInput = EncoderInput(
            transformation: parent.transformation,
            baseSequence: lifted.sequence,
            tree: lifted.tree,
            graph: lifted.graph,
            warmStartRecords: [:]
        )
        let nestedHasDescendant = lifted.graph.composableNestedBind(
            under: nestedBind.nodeID,
            seenBindFingerprints: nestedChain.seenBindFingerprints
        ) != nil
        let nestedEncoder = makeBoundValueCompositionEncoder(
            bindNodeID: nestedBind.nodeID,
            controllerLeafNodeID: nestedControllerLeafNodeID,
            controllerSequenceIndex: lifted.graph.nodes[nestedControllerLeafNodeID].positionRange?.lowerBound,
            stage: nestedHasDescendant ? .chainInterior : .chainTail,
            chain: nestedChain,
            totalProbeCap: 0
        )
        return .stage(encoder: .composed(nestedEncoder), scope: nestedInput)
    }

    /// Builds the value search over the lifted bound subtree's leaves: binary search for one leaf, covering for several.
    private static func terminalStage(
        lifted: LiftedBind,
        upstreamProposedBitPattern: UInt64?,
        parent: EncoderInput,
        chain: BoundValueChain
    ) -> DownstreamBuild {
        let liftedGraph = lifted.graph
        let boundLeaves = liftedGraph.leafNodes.filter { leafID in
            guard let range = liftedGraph.nodes[leafID].positionRange else { return false }
            if liftedGraph.nodes[leafID].scopeAnnotation.isDepthControl { return false }
            return lifted.boundRange.contains(range.lowerBound)
        }

        guard chain.admitsTerminalSearch(liftedSequenceCount: lifted.sequence.count) else {
            return .failed(.liftedTooLong)
        }
        // Nested bind inners stay fixed when the bound subtree is not a single chain. Changing one without recursively rebuilding its descendants produces an exact candidate with stale structure.
        let freeLeaves = boundLeaves.filter {
            liftedGraph.nodes[$0].scopeAnnotation.isBindInner == false
        }
        let downstreamLeaves = freeLeaves.isEmpty ? boundLeaves : freeLeaves
        guard downstreamLeaves.isEmpty == false else {
            return .failed(.noDownstreamLeaves)
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
        return .stage(encoder: downstreamEncoder, scope: downstreamScope)
    }

    /// Counts the stages a composition rooted at `bindNodeID` can build in `graph`: the root plus each nested bind ``ChoiceGraph/composableNestedBind(under:seenBindFingerprints:)`` descends into. The walk stops where composition stops, at a branching dependency or a repeated fingerprint.
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
        while let nested = graph.composableNestedBind(
            under: current,
            seenBindFingerprints: seen
        ) {
            seen.insert(nested.metadata.fingerprint)
            current = nested.nodeID
            length += 1
        }
        return length
    }
}
