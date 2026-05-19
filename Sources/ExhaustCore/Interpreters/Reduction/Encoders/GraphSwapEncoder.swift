//
//  GraphSwapEncoder.swift
//  Exhaust
//

// MARK: - Graph Swap Encoder

/// Reorders same-shaped siblings within a parent node (zip) for shortlex improvement.
///
/// After a successful initial swap, adaptively extends by pushing the moved content further rightward via doubling (the ``find_integer`` pattern). Each probe is a single pairwise swap using the existing ``ProjectedMutation/siblingsSwapped(parentNodeID:idA:idB:)`` mutation — no new mutation types are needed.
///
/// For groups of two, behaves as a single-shot encoder (one swap, done). For groups of three or more, the adaptive extension tries to move the content to its final position in O(log N) probes instead of O(N) sequential swaps.
///
/// Candidate construction and the adaptive extension loop live in `GraphStructuralEncoder+Swap.swift`.
struct GraphSwapEncoder: GraphEncoder {
    let name: EncoderName = .siblingSwap

    // MARK: - State

    /// The initial mutation built at ``start(scope:)``. Consumed on the first ``nextProbe(into:lastAccepted:)`` call.
    private var initialProbe: EncoderProbe?

    /// The candidate sequence for the initial probe, stored alongside ``initialProbe``.
    private var initialProbeCandidate: ChoiceSequence?

    /// Adaptive extension state. Non-nil when the initial probe targeted a group of three or more and extension is viable. Set at ``start(scope:)`` alongside the initial probe.
    var extensionState: ExtensionState?

    /// Mutable state for the adaptive rightward extension.
    struct ExtensionState {
        let parentNodeID: Int
        /// Full group of same-shaped sibling node IDs with their position ranges, sorted by position.
        let slots: [(nodeID: Int, range: ClosedRange<Int>)]
        /// The sequence as it was after the last accepted swap. Used as the base for building the next extension candidate.
        var runningSequence: ChoiceSequence
        /// Index into ``slots`` of the slot currently holding the content being pushed rightward.
        var contentSlotIndex: Int
        /// The farthest slot index that was accepted (content successfully moved there).
        var acceptedSlotIndex: Int
        /// Adaptive step size: doubles on success, triggers bisection on failure.
        var step: Int
        /// When non-nil, the encoder is bisecting between ``acceptedSlotIndex`` and ``bisectHi`` (rejected).
        var bisectHi: Int?
        /// True until the first ``nextExtensionProbe`` feedback is consumed. The first call carries feedback for the initial swap, not an extension probe, so the state-advancement must be skipped.
        var awaitingInitialFeedback = true
    }

    // MARK: - GraphEncoder

    mutating func refreshState(graph _: ChoiceGraph, sequence: ChoiceSequence) {
        initialProbe = nil
        initialProbeCandidate = nil
        if var ext = extensionState {
            ext.runningSequence = sequence
            extensionState = ext
        }
    }

    mutating func start(scope: EncoderInput) {
        initialProbe = nil
        initialProbeCandidate = nil
        extensionState = nil

        guard case let .permute(permutationScope) = scope.transformation.operation else {
            return
        }

        var candidateBuffer = scope.baseSequence
        initialProbe = buildInitialProbe(
            into: &candidateBuffer,
            scope: permutationScope,
            sequence: scope.baseSequence,
            graph: scope.graph
        )
        if initialProbe != nil {
            initialProbeCandidate = candidateBuffer
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        // Initial probe: return it once, then clear.
        if initialProbe != nil {
            return nextInitialProbe(into: &candidate)
        }

        // Adaptive extension: active after the initial probe was consumed.
        if extensionState != nil {
            return nextExtensionProbe(into: &candidate, lastAccepted: lastAccepted)
        }

        return nil
    }

    /// Consumes the pre-built initial probe, writing its candidate into the buffer.
    private mutating func nextInitialProbe(into candidate: inout ChoiceSequence) -> EncoderProbe? {
        guard let stored = initialProbe else { return nil }
        initialProbe = nil
        if let storedCandidate = initialProbeCandidate {
            candidate = storedCandidate
            initialProbeCandidate = nil
        }
        return stored
    }
}
