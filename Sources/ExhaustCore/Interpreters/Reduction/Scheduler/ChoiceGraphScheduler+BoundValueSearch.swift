//
//  ChoiceGraphScheduler+BoundValueSearch.swift
//  Exhaust
//

// MARK: - Bound Value Composition Construction

extension ChoiceGraphScheduler {
    /// Builds a ``GraphComposedEncoder`` for a bound value scope.
    ///
    /// The upstream encoder is a ``GraphBinarySearchEncoder`` operating on a synthesized one-leaf integer scope targeting the bind's ``BoundValueScope/upstreamLeafNodeID``.
    ///
    /// The downstream encoder depends on the bound subtree's leaf count: a ``GraphBinarySearchEncoder`` for single-leaf subtrees, or a ``GraphBoundValueCoveringEncoder`` for multi-leaf subtrees. The downstream is started by the lift closure on the lifted graph's bound-subtree leaves.
    ///
    /// The lift materializes each upstream candidate through `gen`, builds a fresh graph from the resulting tree, and constructs the downstream scope on the lifted graph's bound-subtree leaves.
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
        // Upstream: pure binary search over the bind-inner leaf, no inline linear scan or cross-zero phases. ``GraphValueEncoder``'s extra phases are wasted in a bound value context — every upstream probe spawns one lift and a full downstream search, so the standalone encoder's recovery strategies multiply the cost without finding more failures.
        //
        // Downstream: choose encoder based on bound subtree dimensionality.
        // Single-leaf bound subtrees use binary search — the covering encoder requires ≥ 2 parameters for pairwise covering and falls through with zero probes for large single-parameter domains. Binary search converges in O(log domain) steps and correctly handles the cross-zero phase for signed types, finding the minimum failing value directly.
        // Multi-leaf bound subtrees use BoundValueCoveringEncoder to discover failures across combinations.
        let downstreamEncoder: EncoderDispatch = bindScope.downstreamNodeIDs.count == 1
            ? .binarySearch(GraphBinarySearchEncoder())
            : .boundValueCovering(GraphBoundValueCoveringEncoder())

        let lift: (ChoiceSequence, EncoderProbe, EncoderInput) -> EncoderInput? = { upstreamCandidate, upstreamMutation, parent in
            Self.boundValueLift(
                upstreamCandidate: upstreamCandidate,
                upstreamMutation: upstreamMutation,
                parent: parent,
                graph: graph,
                bindScope: bindScope,
                gen: gen
            )
        }

        return .composed(GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: upstreamScope,
            downstream: downstreamEncoder,
            upstreamBudget: upstreamBudget,
            totalProbeCap: totalProbeCap,
            lift: lift
        ))
    }

    /// Lifts an upstream probe into a downstream ``EncoderInput`` for the bound value composition.
    ///
    /// 1. Materializes the upstream candidate through `gen` to obtain the new bound subtree's choice tree.
    /// 2. Builds a fresh ``ChoiceGraph`` from the materialized tree. The upstream probe changes a bind-inner value, which can restructure the bound subtree — a full build is the only reliable path when the structure changes.
    /// 3. Locates the bind's bound child in the lifted graph and collects its descendant leaves as the downstream search range.
    /// 4. Constructs an integer-leaves minimization scope on the lifted graph; the downstream encoder operates on it without knowing it is downstream.
    static func boundValueLift(
        upstreamCandidate: ChoiceSequence,
        upstreamMutation _: EncoderProbe,
        parent: EncoderInput,
        graph _: ChoiceGraph,
        bindScope: BoundValueScope,
        gen: AnyGenerator
    ) -> EncoderInput? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)

        // Read the proposed upstream value for instrumentation.
        let upstreamSeqIndex = parent.graph.nodes[bindScope.upstreamLeafNodeID].positionRange?.lowerBound
        let upstreamProposedBitPattern: UInt64? = upstreamSeqIndex.flatMap { i in
            i < upstreamCandidate.count
                ? upstreamCandidate[i].value?.choice.bitPattern64
                : nil
        }

        // 1. Materialize through the generator to get the new bound subtree. Use guided mode so that downstream coordinates outside the new range get re-resolved from the fallback tree (or PRNG when the fallback has no info) instead of being rejected. The upstream candidate carries the *previous* downstream values, which are typically out-of-range for the new upstream value (Coupling: dropping `n` from 2 to 1 makes the array element value `2`
        //    out-of-range for the new `int(in: 0...1)` element generator). Mirrors
        //    the bound-value composition's lift configuration.
        guard case let .success(_, freshTree, _) = Materializer.materializeAny(
            gen,
            prefix: upstreamCandidate,
            mode: .guided(seed: 0, fallbackTree: parent.tree),
            fallbackTree: parent.tree,
            materializePicks: true
        ) else {
            Self.logReducer("bound_value_lift_failed", isInstrumented: isInstrumented, metadata: [
                "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
                "candidate_len": "\(upstreamCandidate.count)",
            ])
            return nil
        }

        // 2. Gate: the lifted tree must not be larger than the current best sequence. Structural bind-inner changes can produce a freshTree with a different entry layout (the guided materializer falls back to PRNG for mismatched entries), so compare total entry counts rather than attempting an incremental reshape that would diverge.
        let liftedSequence = ChoiceSequence(freshTree)
        guard liftedSequence.count <= parent.baseSequence.count else {
            return nil
        }

        // 3. Build the lifted graph from the freshTree. The upstream probe changes a bind-inner value, which can restructure the bound subtree — a full build is the only reliable path when the structure changes.
        let liftedGraph = ChoiceGraph.build(from: freshTree)

        // 5. Find the bound child of the target bind in the lifted graph, then collect its descendant leaves as the downstream search range.
        guard bindScope.bindNodeID < liftedGraph.nodes.count,
              case let .bind(metadata) = liftedGraph.nodes[bindScope.bindNodeID].kind,
              liftedGraph.nodes[bindScope.bindNodeID].children.count > metadata.boundChildIndex
        else {
            return nil
        }
        let boundChildID = liftedGraph.nodes[bindScope.bindNodeID].children[metadata.boundChildIndex]
        guard let boundRange = liftedGraph.nodes[boundChildID].positionRange else {
            return nil
        }

        let downstreamLeaves = liftedGraph.leafNodes.filter { leafID in
            guard let range = liftedGraph.nodes[leafID].positionRange else { return false }
            if liftedGraph.nodes[leafID].scopeAnnotation.isDepthControl { return false }
            return boundRange.contains(range.lowerBound)
        }
        guard downstreamLeaves.isEmpty == false else { return nil }

        // 6. Build the downstream scope as a plain integer-leaves minimization on the lifted graph. The downstream encoder doesn't know it's downstream.
        Self.logReducer("bound_value_lift_built", isInstrumented: isInstrumented, metadata: [
            "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
            "parent_seq_len": "\(parent.baseSequence.count)",
            "lifted_seq_len": "\(liftedSequence.count)",
            "downstream_leaves": "\(downstreamLeaves.count)",
            "bound_range": "\(boundRange.lowerBound)...\(boundRange.upperBound)",
        ])
        return EncoderInput(
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
    }
}
