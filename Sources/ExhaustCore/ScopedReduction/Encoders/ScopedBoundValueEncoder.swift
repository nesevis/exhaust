//
//  ScopedBoundValueEncoder.swift
//  Exhaust
//

// MARK: - Bound Value Encoder

/// Lowers a bind's controller value and searches the bound content each lower value generates.
///
/// Each controller proposal is lifted through the generator, because the bound subtree depends on the controller. After relocating the bind in the lifted graph, the branch either descends into the next nested bind or searches the bound leaves. A chain of nested binds is a chain of nested `propose`s, written as recursion that follows the generator's nesting. The terminal search is a ``ScopedBinarySearch`` for one leaf or a ``ScopedCoveringSearch`` for several. Turns, search budgets, chain build limits, the shared pool, and the build tally belong to the interpreter, driven by each level's ``ScopedChoiceConfiguration``; every budget comes from ``ScopedReductionTuning``.
enum ScopedBoundValueEncoder: ScopedEncoder {
    static let name: EncoderName = .boundValueSearch
    static let isValueDependent = true
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    /// Reads its upstream budget and probe cap from the ``ScopedDispatchBudget`` its bind classification gate resolves.
    static func reducer(_ bindScope: BoundValueScope, input: ScopedEncoderInput) -> ScopedReducer {
        guard let budget = input.dispatchBudget else {
            preconditionFailure("A bound value dispatch carries the budget its bind classification gate resolves")
        }
        let graph = input.graph
        var seenBindFingerprints: Set<UInt64> = []
        if bindScope.bindNodeID < graph.nodes.count,
           case let .bind(metadata) = graph.nodes[bindScope.bindNodeID].kind
        {
            seenBindFingerprints.insert(metadata.fingerprint)
        }
        let chainLength = Self.composableChainLength(
            from: bindScope.bindNodeID,
            graph: graph,
            seenBindFingerprints: seenBindFingerprints
        )
        return Self.level(
            scope: input,
            bindNodeID: bindScope.bindNodeID,
            controllerLeafNodeID: bindScope.upstreamLeafNodeID,
            stage: chainLength > 1 ? .chainRoot : .single,
            chain: Chain(
                upstreamBudget: budget.upstreamBudget,
                rootSequence: input.baseSequence,
                seenBindFingerprints: seenBindFingerprints,
                depth: 0,
                buildPoolCapacity: input.tuning.nestedChainBuildPool(chainLength: chainLength)
            ),
            totalProbeCap: budget.totalProbeCap,
            rootMutation: nil
        )
    }

    /// Values every level of one chain shares. The generator, build tally, and build pool belong to the decoder and interpreter, so the encoder's reducer captures none of them.
    private struct Chain {
        let upstreamBudget: Int
        let rootSequence: ChoiceSequence
        let seenBindFingerprints: Set<UInt64>
        let depth: Int
        let buildPoolCapacity: Int

        func descending(into fingerprint: UInt64) -> Chain {
            var fingerprints = seenBindFingerprints
            fingerprints.insert(fingerprint)
            return Chain(
                upstreamBudget: upstreamBudget,
                rootSequence: rootSequence,
                seenBindFingerprints: fingerprints,
                depth: depth + 1,
                buildPoolCapacity: buildPoolCapacity
            )
        }
    }

    /// One composition level. `rootMutation` is the outermost proposal's reshaped mutation, which every candidate in the chain reports, because an acceptance has to rebuild from the outermost controller's change.
    private static func level(
        scope: ScopedEncoderInput,
        bindNodeID: Int,
        controllerLeafNodeID: Int,
        stage: BoundValueStage,
        chain: Chain,
        totalProbeCap: Int,
        rootMutation: EncoderProbe?
    ) -> ScopedReducer {
        let chainLimits: ScopedChainLimits? = switch stage {
            case .single:
                nil
            case .chainRoot, .chainInterior, .chainTail:
                ScopedChainLimits(
                    maxBuildsPerStart: scope.tuning.nestedChainBuildsPerStart(depth: chain.depth),
                    poolCapacity: chain.buildPoolCapacity
                )
        }
        // The probe cap is sized for turns: two-probe turns give the controller candidate at index k its second probe after 2(k + 1) probes, where diagonal grades by index need (k + 2)(k + 3) / 2 - 1.
        let scheduling: ScopedChoiceScheduling = totalProbeCap > 0 ? .turnBased : .diagonal
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: chainLimits == nil ? nil : scope.tuning.probesPerControllerCandidateTurn,
            searchBudget: chain.upstreamBudget,
            totalProbeCap: totalProbeCap,
            chainLimits: chainLimits,
            scheduling: scheduling
        )
        return .propose(
            { controllerProposals(scope: scope, controllerLeafNodeID: controllerLeafNodeID, stage: stage) },
            configuration: configuration,
            then: { proposal in
                let reportedMutation = rootMutation ?? ScopedComposition.reshaping(proposal.mutation)
                return .lift(
                    proposal.prefix,
                    fallbackTree: scope.tree,
                    maximumSequenceCount: stage.canRecurseIntoNestedBind ? nil : chain.rootSequence.count
                ) { lifted in
                    guard let lifted else {
                        return .fail(.materializationFailed)
                    }
                    return downstream(
                        lifted: lifted,
                        proposal: proposal,
                        scope: scope,
                        bindNodeID: bindNodeID,
                        controllerLeafNodeID: controllerLeafNodeID,
                        stage: stage,
                        chain: chain,
                        reportedMutation: reportedMutation
                    )
                }
            }
        )
    }

    /// Relocates the bind, then descends into a composable nested bind or builds the terminal search.
    private static func downstream(
        lifted: LiftResult,
        proposal: LiftProposal,
        scope: ScopedEncoderInput,
        bindNodeID: Int,
        controllerLeafNodeID: Int,
        stage: BoundValueStage,
        chain: Chain,
        reportedMutation: EncoderProbe
    ) -> ScopedReducer {
        let upstreamSequenceIndex = scope.graph.nodes[controllerLeafNodeID].positionRange?.lowerBound
        let upstreamProposedBitPattern = controllerBitPattern(in: proposal.prefix, at: upstreamSequenceIndex)

        let liftedBind: LiftedBind
        switch locateLiftedBind(
            liftResult: lifted,
            parent: scope,
            bindNodeID: bindNodeID,
            stage: stage,
            rootSequence: chain.rootSequence,
            controllerTopologyOnly: stage.canRecurseIntoNestedBind
        ) {
            case let .lifted(located):
                liftedBind = located
            case let .failed(reason):
                return .fail(reason)
        }

        if stage.canRecurseIntoNestedBind,
           let nestedBind = liftedBind.graph.composableNestedBind(
               under: liftedBind.bindNodeID,
               seenBindFingerprints: chain.seenBindFingerprints
           )
        {
            let nestedControllerLeafNodeID = liftedBind.graph.nodes[nestedBind.nodeID].children[nestedBind.metadata.innerChildIndex]
            let nestedChain = chain.descending(into: nestedBind.metadata.fingerprint)
            let nestedInput = ScopedEncoderInput(
                baseSequence: liftedBind.sequence,
                tree: liftedBind.tree,
                graph: liftedBind.graph,
                warmStartRecords: [:],
                tuning: scope.tuning,
                coveringRowCache: scope.coveringRowCache
            )
            let nestedHasDescendant = liftedBind.graph.composableNestedBind(
                under: nestedBind.nodeID,
                seenBindFingerprints: nestedChain.seenBindFingerprints
            ) != nil
            return level(
                scope: nestedInput,
                bindNodeID: nestedBind.nodeID,
                controllerLeafNodeID: nestedControllerLeafNodeID,
                stage: nestedHasDescendant ? .chainInterior : .chainTail,
                chain: nestedChain,
                totalProbeCap: 0,
                rootMutation: reportedMutation
            )
        }

        return terminal(
            lifted: liftedBind,
            upstreamProposedBitPattern: upstreamProposedBitPattern,
            parent: scope,
            rootSequence: chain.rootSequence,
            reportedMutation: reportedMutation
        )
    }

    /// Builds the value search over the lifted bound subtree's leaves: binary search for one leaf, covering for several.
    private static func terminal(
        lifted: LiftedBind,
        upstreamProposedBitPattern: UInt64?,
        parent: ScopedEncoderInput,
        rootSequence: ChoiceSequence,
        reportedMutation: EncoderProbe
    ) -> ScopedReducer {
        if BoundValueTerminalOrder.rejectsTerminal(lifted, incumbent: rootSequence) {
            return .fail(.nonImprovingPrefix)
        }
        let liftedGraph = terminalGraph(of: lifted)
        let boundLeaves = liftedGraph.leafNodes.filter { leafID in
            guard let range = liftedGraph.nodes[leafID].positionRange else {
                return false
            }
            if liftedGraph.nodes[leafID].scopeAnnotation.isDepthControl {
                return false
            }
            return lifted.boundRange.contains(range.lowerBound)
        }

        guard admitsTerminalSearch(liftedSequence: lifted.sequence, rootSequence: rootSequence) else {
            return .fail(.liftedTooLong)
        }
        // Nested bind inners stay fixed when the bound subtree is not a single chain. Changing one without recursively rebuilding its descendants produces an exact candidate with stale structure.
        let freeLeaves = boundLeaves.filter {
            liftedGraph.nodes[$0].scopeAnnotation.isBindInner == false
        }
        let downstreamLeaves = freeLeaves.isEmpty ? boundLeaves : freeLeaves
        guard downstreamLeaves.isEmpty == false else {
            return .fail(.noDownstreamLeaves)
        }

        let leafEntries = downstreamLeaves.map {
            LeafEntry(nodeID: $0, mayReshapeOnAcceptance: false)
        }
        let search: any ScopedSearch = downstreamLeaves.count == 1
            ? ScopedBinarySearch(leaves: leafEntries, graph: liftedGraph, baseSequence: lifted.sequence)
            : ScopedCoveringSearch(
                leaves: leafEntries,
                graph: liftedGraph,
                baseSequence: lifted.sequence,
                tuning: parent.tuning,
                rowCache: parent.coveringRowCache
            )

        ScopedReductionLog.reducer("bound_value_lift_built", isInstrumented: ExhaustLog.isEnabled(.debug, for: .reducer), metadata: [
            "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
            "parent_seq_len": "\(parent.baseSequence.count)",
            "lifted_seq_len": "\(lifted.sequence.count)",
            "downstream_leaves": "\(downstreamLeaves.count)",
            "bound_range": "\(lifted.boundRange.lowerBound)...\(lifted.boundRange.upperBound)",
        ])
        return .search(
            search,
            configuration: ScopedSearchConfiguration(
                acceptance: .stop,
                requiresExactDecoder: true,
                reportedMutation: reportedMutation
            )
        )
    }

    /// Proposes controller values for one composition stage: binary-search midpoints for a single bind, domain enumeration for a chain stage. Nil when the controller is not a value leaf, or when a chain stage's controller is floating point.
    private static func controllerProposals(
        scope: ScopedEncoderInput,
        controllerLeafNodeID: Int,
        stage: BoundValueStage
    ) -> LeafProposalCursor? {
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
        return LeafProposalCursor(
            graph: scope.graph,
            baseSequence: scope.baseSequence,
            leafNodeID: controllerLeafNodeID,
            candidates: candidates
        )
    }

    /// The controller's proposed bit pattern, for logging. Nil when the controller position falls outside the proposed prefix.
    private static func controllerBitPattern(in sequence: ChoiceSequence, at index: Int?) -> UInt64? {
        index.flatMap { sequenceIndex in
            sequenceIndex < sequence.count ? sequence[sequenceIndex].value?.choice.bitPattern64 : nil
        }
    }

    /// Locates the dispatched bind in the lifted graph, rejecting terminal-only growth before paying for graph construction.
    private static func locateLiftedBind(
        liftResult: LiftResult,
        parent: ScopedEncoderInput,
        bindNodeID: Int,
        stage: BoundValueStage,
        rootSequence: ChoiceSequence,
        controllerTopologyOnly: Bool
    ) -> BoundValueLift {
        let freshTree = liftResult.tree
        let liftedSequence = liftResult.sequence
        // A stage that cannot recurse always ends in a terminal search, so a lift the terminal search would reject is dropped before the graph build.
        if stage.canRecurseIntoNestedBind == false,
           admitsTerminalSearch(liftedSequence: liftedSequence, rootSequence: rootSequence) == false
        {
            return .failed(.liftedTooLong)
        }
        guard bindNodeID < parent.graph.nodes.count,
              case let .bind(sourceMetadata) = parent.graph.nodes[bindNodeID].kind,
              let (liftedGraph, liftedBindNodeID) = liftedGraph(
                  of: freshTree,
                  bindPath: sourceMetadata.bindPath,
                  fingerprint: sourceMetadata.fingerprint,
                  controllerTopologyOnly: controllerTopologyOnly
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
            boundRange: boundRange,
            isControllerTopology: controllerTopologyOnly
        ))
    }

    /// Builds the lifted graph from the dispatched bind down, because nothing outside the bind's subtree is read. Falls back to a full build where ``ChoiceGraphBuilder/buildBind(at:fingerprint:in:omittingScalarSequenceElements:)`` declines.
    private static func liftedGraph(
        of tree: ChoiceTree,
        bindPath: ChoicePath,
        fingerprint: UInt64,
        controllerTopologyOnly: Bool
    ) -> (graph: ChoiceGraph, bindNodeID: Int)? {
        if let bindRooted = ChoiceGraphBuilder.buildBind(
            at: bindPath,
            fingerprint: fingerprint,
            in: tree,
            omittingScalarSequenceElements: controllerTopologyOnly
        ) {
            return bindRooted
        }
        let graph = controllerTopologyOnly
            ? ChoiceGraphBuilder.buildControllerTopology(from: tree)
            : ChoiceGraph.build(from: tree)
        guard let bindNodeID = graph.bindNodeID(fingerprint: fingerprint, path: bindPath) else {
            return nil
        }
        return (graph, bindNodeID)
    }

    /// The graph a terminal search runs on: the lifted graph, or for a controller topology, which omits scalar array elements, the bind's subtree built in full.
    private static func terminalGraph(of lifted: LiftedBind) -> ChoiceGraph {
        guard lifted.isControllerTopology,
              case let .bind(metadata) = lifted.graph.nodes[lifted.bindNodeID].kind,
              let full = liftedGraph(of: lifted.tree, bindPath: metadata.bindPath, fingerprint: metadata.fingerprint, controllerTopologyOnly: false)
        else {
            return lifted.terminalGraph()
        }
        return full.graph
    }

    /// Whether a terminal search may run on a lift of this length. Only terminal searches are gated, so an intermediate lift can grow while a deeper controller compensates.
    private static func admitsTerminalSearch(liftedSequence: ChoiceSequence, rootSequence: ChoiceSequence) -> Bool {
        liftedSequence.count <= rootSequence.count
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

// MARK: - Dispatch Requirements

extension ScopedBoundValueEncoder {
    static func gate(_ scope: BoundValueScope) -> ScopedDispatchGate {
        .bindClassification(bindNodeID: scope.bindNodeID, upstreamLeafNodeID: scope.upstreamLeafNodeID)
    }

    /// The bound subtree's positions, whose convergence the pass's lifts invalidated.
    static func convergenceInvalidatedByAcceptance(_ scope: BoundValueScope, in graph: ChoiceGraph) -> ClosedRange<Int>? {
        guard scope.bindNodeID < graph.nodes.count,
              case let .bind(bindMetadata) = graph.nodes[scope.bindNodeID].kind,
              graph.nodes[scope.bindNodeID].children.count > bindMetadata.boundChildIndex
        else {
            return nil
        }
        let boundChildID = graph.nodes[scope.bindNodeID].children[bindMetadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange
    }

    static func isValid(_: BoundValueScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
