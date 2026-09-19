//
//  GraphDepthCollapseEncoder.swift
//  Exhaust
//

/// Binary searches a ``TypeTag/depthControl`` value toward its range floor, marking each probe as reshaping.
///
/// The search itself is ``GraphBinarySearchEncoder``: a depth leaf is an ordinary bounded integer, and finding the smallest failing layer count is the same problem as finding the smallest failing value. This wrapper exists for two reasons the inner encoder cannot serve on its own.
///
/// First, the probe is a reshape. A depth leaf is the inner of a `._bound`, so accepting a lower value rebuilds the subtree that bind governs rather than editing an entry in place. ``GraphBinarySearchEncoder`` reports `mayReshape: false` because its usual caller, the upstream of a ``GraphComposedEncoder``, has the composition flip the flag on the way out. Dispatched directly there is no composition, so the flag is flipped here.
///
/// Second, the name. Reporting ``EncoderName/depthCollapse`` rather than ``EncoderName/valueSearch`` keeps depth probes separable in ``ReductionStats`` and lets ``ReducerConfiguration/enabledEncoders`` isolate the pass.
struct GraphDepthCollapseEncoder: GraphEncoder {
    let name: EncoderName = .depthCollapse

    private var inner = GraphBinarySearchEncoder()
    private var isStarted = false

    mutating func start(scope: EncoderInput) {
        isStarted = false
        guard case let .minimize(.depthCollapse(depthScope)) = scope.transformation.operation else {
            return
        }
        // The inner encoder reads a `.valueLeaves` scope. Everything else about the input is carried through unchanged.
        inner.start(scope: EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(depthScope)),
                priority: scope.transformation.priority
            ),
            baseSequence: scope.baseSequence,
            tree: scope.tree,
            graph: scope.graph,
            warmStartRecords: scope.warmStartRecords
        ))
        isStarted = true
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard isStarted else { return nil }
        guard let probe = inner.nextProbe(into: &candidate, lastAccepted: lastAccepted) else {
            return nil
        }
        guard case let .leafValues(changes) = probe else {
            return probe
        }
        return .leafValues(changes.map { change in
            LeafChange(
                leafNodeID: change.leafNodeID,
                newValue: change.newValue,
                mayReshape: true
            )
        })
    }
}
