//
//  ChoiceGraphScheduler+BoundValueSearch.swift
//  Exhaust
//

// MARK: - Bound Value Composition Construction

extension ChoiceGraphScheduler {
    /// Builds a ``GraphComposedEncoder`` for a bound value scope.
    ///
    /// The upstream encoder is a ``GraphBinarySearchEncoder`` operating on a synthesised one-leaf integer scope targeting the fibre's ``BoundValueScope/upstreamLeafNodeID``. The downstream encoder is a ``GraphBinarySearchEncoder`` for single-leaf fibres or a ``GraphFibreCoveringEncoder`` for multi-leaf fibres, started by the lift closure on the lifted graph's bound-subtree leaves. The lift materializes each upstream candidate through `gen`, copies the parent graph, applies the upstream change to the copy via ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)``, and constructs the downstream scope on the resulting graph.
    ///
    /// - Parameters:
    ///   - fibreScope: The bound value scope from the source pipeline.
    ///   - scope: The dispatched ``TransformationScope``. Used to seed the upstream encoder's one-leaf scope and to provide the parent tree as the lift's fallback.
    ///   - gen: The generator. Captured by the lift closure for materialisation.
    ///   - upstreamBudget: Maximum number of upstream probes the composition will explore. Decayed by ``ChoiceGraphScheduler/runCore(gen:initialTree:initialOutput:config:collectStats:property:)`` based on per-bind stall counts.
    static func makeBoundValueComposition(
        fibreScope: BoundValueScope,
        scope: TransformationScope,
        gen: ReflectiveGenerator<Any>,
        upstreamBudget: Int = 15
    ) -> any GraphEncoder {
        // Synthesise the upstream scope: a one-leaf integer minimization on the bind-inner. ``mayReshapeOnAcceptance`` is false here because the composition synthesises the reshape change in ``GraphComposedEncoder/wrap``
        // when wrapping each downstream probe — the upstream encoder produces a pure value-only mutation and the composition flips ``mayReshape`` on its way out.
        let upstreamLeafEntry = LeafEntry(
            nodeID: fibreScope.upstreamLeafNodeID,
            mayReshapeOnAcceptance: false
        )
        let upstreamScope = TransformationScope(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(ValueMinimizationScope(
                    leaves: [upstreamLeafEntry],
                    batchZeroEligible: false
                ))),
                yield: scope.transformation.yield,
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ),
            baseSequence: scope.baseSequence,
            tree: scope.tree,
            graph: scope.graph,
            warmStartRecords: [:]
        )
        // Upstream: pure binary search over the bind-inner leaf, no inline linear scan or cross-zero phases. ``GraphValueEncoder``'s extra phases are wasted in a bound value context — every upstream probe spawns one lift and a full downstream search, so the standalone encoder's recovery strategies multiply the cost without finding more failures.
        //
        // Downstream: choose encoder based on fibre dimensionality.
        // Single-leaf fibres use binary search — the covering encoder requires ≥ 2 parameters for pairwise covering and falls through with zero probes for large single-parameter domains. Binary search converges in O(log domain) steps and correctly handles the cross-zero phase for signed types, finding the minimum failing value directly.
        // Multi-leaf fibres use FibreCoveringEncoder to discover failures across combinations.
        let downstreamEncoder: any GraphEncoder = fibreScope.downstreamNodeIDs.count == 1
            ? GraphBinarySearchEncoder()
            : GraphFibreCoveringEncoder()

        let lift: (EncoderProbe, TransformationScope) -> TransformationScope? = { upstreamProbe, parent in
            Self.boundValueLift(
                upstreamProbe: upstreamProbe,
                parent: parent,
                fibreScope: fibreScope,
                gen: gen
            )
        }

        return GraphComposedEncoder(
            name: .composed,
            upstream: GraphBinarySearchEncoder(),
            upstreamScope: upstreamScope,
            downstream: downstreamEncoder,
            upstreamBudget: upstreamBudget,
            lift: lift
        )
    }

    /// Lifts an upstream probe into a downstream ``TransformationScope`` for the bound value composition.
    ///
    /// 1. Materialises the upstream candidate through `gen` to obtain the new fibre's choice tree.
    /// 2. Copies the parent graph and applies the upstream change to the copy as a reshape (`mayReshape: true`), so ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` splices the rebuilt bound subtree from the freshTree on the throwaway copy. Falls back to a full ``ChoiceGraph/build(from:)`` if the partial path bails.
    /// 3. Locates the bind's bound child in the lifted graph and collects its descendant leaves as the downstream search range.
    /// 4. Constructs an integer-leaves minimization scope on the lifted graph; the downstream encoder operates on it without knowing it is downstream.
    static func boundValueLift(
        upstreamProbe: EncoderProbe,
        parent: TransformationScope,
        fibreScope: BoundValueScope,
        gen: ReflectiveGenerator<Any>
    ) -> TransformationScope? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)

        // Read the proposed upstream value for instrumentation.
        let upstreamSeqIndex = parent.graph.nodes[fibreScope.upstreamLeafNodeID].positionRange?.lowerBound
        let upstreamProposedBitPattern: UInt64? = upstreamSeqIndex.flatMap { i in
            i < upstreamProbe.candidate.count
                ? upstreamProbe.candidate[i].value?.choice.bitPattern64
                : nil
        }

        // 1. Materialise through the generator to get the new fibre. Use guided mode so that downstream coordinates outside the new range get re-resolved from the fallback tree (or PRNG when the fallback has no info) instead of being rejected. The upstream candidate carries the *previous* downstream values, which are typically out-of-range for the new upstream value (Coupling: dropping `n` from 2 to 1 makes the array element value `2`
        //    out-of-range for the new `int(in: 0...1)` element generator). Mirrors
        //    ``ReductionState/compositionDescriptors``'s lift configuration.
        guard case let .success(_, freshTree, _) = Materializer.materializeAny(
            gen,
            prefix: upstreamProbe.candidate,
            mode: .guided(seed: 0, fallbackTree: parent.tree),
            fallbackTree: parent.tree,
            materializePicks: true
        ) else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "bound_value_lift_failed",
                    metadata: [
                        "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
                        "candidate_len": "\(upstreamProbe.candidate.count)",
                    ]
                )
            }
            return nil
        }

        // 2. Build a reshape change from the upstream's mutation. The upstream encoder reports a value-only LeafChange (mayReshape: false); we lift it to mayReshape: true so applyBindReshape rebuilds the bound subtree.
        guard case let .leafValues(upstreamChanges) = upstreamProbe.mutation,
              let upstreamChange = upstreamChanges.first
        else {
            return nil
        }
        let reshapeChange = LeafChange(
            leafNodeID: upstreamChange.leafNodeID,
            newValue: upstreamChange.newValue,
            mayReshape: true
        )

        // 3. Copy the parent graph and apply the reshape on the copy. COW means only the bind subtree region is duplicated; the rest of the graph stays shared with the parent.
        let copy = parent.graph.copy()
        let application = copy.apply(.leafValues([reshapeChange]), freshTree: freshTree)

        // 4. Fall back to a full rebuild if applyBindReshape bailed (multi-pick, structural mismatch, missing metadata). Same fallback the live accept path uses; we just absorb it in the lift instead.
        let liftedGraph: ChoiceGraph = application.requiresFullRebuild
            ? ChoiceGraph.build(from: freshTree)
            : copy

        // 5. Find the bound child of the target bind in the lifted graph, then collect its descendant leaves as the downstream search range.
        guard fibreScope.bindNodeID < liftedGraph.nodes.count,
              case let .bind(metadata) = liftedGraph.nodes[fibreScope.bindNodeID].kind,
              liftedGraph.nodes[fibreScope.bindNodeID].children.count > metadata.boundChildIndex
        else {
            return nil
        }
        let boundChildID = liftedGraph.nodes[fibreScope.bindNodeID].children[metadata.boundChildIndex]
        guard let boundRange = liftedGraph.nodes[boundChildID].positionRange else {
            return nil
        }

        let downstreamLeaves = liftedGraph.leafNodes.filter { leafID in
            guard let range = liftedGraph.nodes[leafID].positionRange else { return false }
            return boundRange.contains(range.lowerBound)
        }
        guard downstreamLeaves.isEmpty == false else { return nil }

        // 6. Build the downstream scope as a plain integer-leaves minimization on the lifted graph. The downstream encoder doesn't know it's downstream.
        let liftedSequence = ChoiceSequence(freshTree)
        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "bound_value_lift_built",
                metadata: [
                    "upstream_bp": upstreamProposedBitPattern.map { "\($0)" } ?? "nil",
                    "parent_seq_len": "\(parent.baseSequence.count)",
                    "lifted_seq_len": "\(liftedSequence.count)",
                    "downstream_leaves": "\(downstreamLeaves.count)",
                    "bound_range": "\(boundRange.lowerBound)...\(boundRange.upperBound)",
                    "rebuild_fallback": "\(application.requiresFullRebuild)",
                ]
            )
        }
        return TransformationScope(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(ValueMinimizationScope(
                    leaves: downstreamLeaves.map {
                        LeafEntry(nodeID: $0, mayReshapeOnAcceptance: false)
                    },
                    batchZeroEligible: downstreamLeaves.count > 1
                ))),
                yield: parent.transformation.yield,
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ),
            baseSequence: liftedSequence,
            tree: freshTree,
            graph: liftedGraph,
            warmStartRecords: [:]
        )
    }
}
