//
//  ChoiceGraphScheduler+BoundValueSearch.swift
//  Exhaust
//

// MARK: - Bound Value Composition Construction

extension ChoiceGraphScheduler {
    /// Probes one controller candidate's downstream search emits before a nested-bind composition moves on to the next candidate. Paused searches resume in later turns, so one controller tuple cannot consume the root's total cap.
    private static let probesPerControllerCandidateTurn = 2

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
        totalProbeCap: Int = 0
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
        let hasComposableNestedBind = composableNestedBindNodeID(
            under: bindScope.bindNodeID,
            graph: graph,
            seenBindFingerprints: seenBindFingerprints
        ) != nil
        return .composed(makeBoundValueCompositionEncoder(
            bindNodeID: bindScope.bindNodeID,
            controllerLeafNodeID: bindScope.upstreamLeafNodeID,
            upstreamScope: upstreamScope,
            stage: hasComposableNestedBind ? .chainRoot : .single,
            chain: BoundValueChain(
                gen: gen,
                upstreamBudget: upstreamBudget,
                rootSequenceCount: scope.baseSequence.count,
                seenBindFingerprints: seenBindFingerprints
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
            probesPerStageTurn: stage.searchesWholeDomain ? probesPerControllerCandidateTurn : nil,
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

    /// Lifts one controller candidate, then builds either the next nested composition or the terminal bound-value search.
    private static func buildBoundValueDownstream(
        upstreamCandidate: ChoiceSequence,
        parent: EncoderInput,
        bindNodeID: Int,
        controllerLeafNodeID: Int,
        stage: BoundValueStage,
        chain: BoundValueChain
    ) -> (encoder: EncoderDispatch, scope: EncoderInput)? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)

        // Read the proposed upstream value for instrumentation.
        let upstreamSeqIndex = parent.graph.nodes[controllerLeafNodeID].positionRange?.lowerBound
        let upstreamProposedBitPattern: UInt64? = upstreamSeqIndex.flatMap { i in
            i < upstreamCandidate.count
                ? upstreamCandidate[i].value?.choice.bitPattern64
                : nil
        }

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
            return nil
        }

        let liftedSequence = ChoiceSequence(freshTree)
        if stage.canRecurseIntoNestedBind == false,
           liftedSequence.count > chain.rootSequenceCount
        {
            return nil
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
            return nil
        }
        let boundChildID = liftedGraph.nodes[liftedBindNodeID].children[metadata.boundChildIndex]
        guard let boundRange = liftedGraph.nodes[boundChildID].positionRange else {
            return nil
        }

        let boundLeaves = liftedGraph.leafNodes.filter { leafID in
            guard let range = liftedGraph.nodes[leafID].positionRange else { return false }
            if liftedGraph.nodes[leafID].scopeAnnotation.isDepthControl { return false }
            return boundRange.contains(range.lowerBound)
        }
        if stage.canRecurseIntoNestedBind,
           let nestedBindNodeID = composableNestedBindNodeID(
               under: liftedBindNodeID,
               graph: liftedGraph,
               seenBindFingerprints: chain.seenBindFingerprints
           )
        {
            guard case let .bind(nestedMetadata) = liftedGraph.nodes[nestedBindNodeID].kind else {
                return nil
            }
            let nestedControllerLeafNodeID = liftedGraph.nodes[nestedBindNodeID].children[nestedMetadata.innerChildIndex]
            let nestedChain = chain.descending(into: nestedMetadata.fingerprint)
            let nestedInput = boundValueInput(
                controllerLeafNodeID: nestedControllerLeafNodeID,
                sequence: liftedSequence,
                tree: freshTree,
                graph: liftedGraph,
                priority: parent.transformation.priority
            )
            let nestedHasDescendant = composableNestedBindNodeID(
                under: nestedBindNodeID,
                graph: liftedGraph,
                seenBindFingerprints: nestedChain.seenBindFingerprints
            ) != nil
            let nestedEncoder = makeBoundValueCompositionEncoder(
                bindNodeID: nestedBindNodeID,
                controllerLeafNodeID: nestedControllerLeafNodeID,
                upstreamScope: nestedInput,
                stage: nestedHasDescendant ? .chainInterior : .chainTail,
                chain: nestedChain,
                totalProbeCap: 0
            )
            return (.composed(nestedEncoder), nestedInput)
        }

        guard liftedSequence.count <= chain.rootSequenceCount else {
            return nil
        }
        // Nested bind inners stay fixed when the bound subtree is not a single chain. Changing one without recursively rebuilding its descendants produces an exact candidate with stale structure.
        let freeLeaves = boundLeaves.filter {
            liftedGraph.nodes[$0].scopeAnnotation.isBindInner == false
        }
        let downstreamLeaves = freeLeaves.isEmpty ? boundLeaves : freeLeaves
        guard downstreamLeaves.isEmpty == false else { return nil }

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
            baseSequence: liftedSequence,
            tree: freshTree,
            graph: liftedGraph,
            warmStartRecords: [:]
        )
        let downstreamEncoder: EncoderDispatch = downstreamLeaves.count == 1
            ? .binarySearch(GraphBinarySearchEncoder())
            : .boundValueCovering(GraphBoundValueCoveringEncoder())

        Self.logReducer("bound_value_lift_built", isInstrumented: isInstrumented, metadata: [
            "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
            "parent_seq_len": "\(parent.baseSequence.count)",
            "lifted_seq_len": "\(liftedSequence.count)",
            "downstream_leaves": "\(downstreamLeaves.count)",
            "bound_range": "\(boundRange.lowerBound)...\(boundRange.upperBound)",
        ])
        return (downstreamEncoder, downstreamScope)
    }

    /// Returns the sole nested bind when composition can descend without revisiting a bind site.
    ///
    /// A repeated fingerprint identifies another expansion of a recursive generator's bind. Treating that expansion as another composition dimension makes work grow with the generated value's recursion depth. Branching dependencies and recursive expansions instead retain their controllers for later scheduler passes.
    private static func composableNestedBindNodeID(
        under bindNodeID: Int,
        graph: ChoiceGraph,
        seenBindFingerprints: Set<UInt64>
    ) -> Int? {
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
        return nestedBindNodeID
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

// MARK: - Supporting Types

/// Where one composition sits in a chain of nested binds. Each case fixes the upstream encoder, whether the controller's current value is a candidate, and whether a lift may descend into a nested bind.
private enum BoundValueStage {
    /// The dispatched bind has no composable nested bind. Binary search over the controller, then a terminal search over the bound leaves.
    case single
    /// The dispatched bind, whose bound subtree holds one composable nested bind. Every lift descends, so the controller can move against a nested one.
    case chainRoot
    /// A nested bind with a further composable nested bind beneath it. Its current value stays a candidate so deeper controllers can move while it holds.
    case chainInterior
    /// The deepest composable nested bind. Every lift ends in a terminal search.
    case chainTail

    /// Whether the controller is enumerated across its domain rather than binary searched toward its target.
    var searchesWholeDomain: Bool {
        switch self {
            case .single:
                false
            case .chainRoot, .chainInterior, .chainTail:
                true
        }
    }

    var includesCurrentController: Bool {
        switch self {
            case .chainInterior:
                true
            case .single, .chainRoot, .chainTail:
                false
        }
    }

    var canRecurseIntoNestedBind: Bool {
        switch self {
            case .chainRoot, .chainInterior:
                true
            case .single, .chainTail:
                false
        }
    }
}

/// State shared by every composition in one chain of nested binds.
private struct BoundValueChain {
    let gen: AnyGenerator
    let upstreamBudget: Int
    /// The live sequence's length at dispatch. Terminal searches reject lifts longer than this; intermediate lifts may exceed it while a deeper controller compensates.
    let rootSequenceCount: Int
    /// Fingerprints of the binds already composed on the path from the root. A repeat marks recursive generator expansion.
    let seenBindFingerprints: Set<UInt64>

    /// The chain one level deeper, with the nested bind's fingerprint recorded.
    func descending(into fingerprint: UInt64) -> BoundValueChain {
        var fingerprints = seenBindFingerprints
        fingerprints.insert(fingerprint)
        return BoundValueChain(
            gen: gen,
            upstreamBudget: upstreamBudget,
            rootSequenceCount: rootSequenceCount,
            seenBindFingerprints: fingerprints
        )
    }
}
