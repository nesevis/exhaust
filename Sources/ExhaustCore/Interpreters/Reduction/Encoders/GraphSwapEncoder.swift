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
        /// Same-shaped sibling slots sorted by position. Each entry names the node whose content currently occupies the slot and the slot's position range in ``runningSequence``. Same-shaped siblings can differ in width, so ranges are recomputed after every accepted swap.
        var slots: [(nodeID: Int, range: ClosedRange<Int>)]
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
        /// Target slot of the emitted probe awaiting feedback, or nil when no probe is outstanding. The initial swap is the first outstanding probe.
        var pendingTargetSlotIndex: Int?
        /// The candidate for the outstanding probe. Becomes ``runningSequence`` only when the probe is accepted.
        var pendingSequence: ChoiceSequence?

        /// Adopts the outstanding probe as the new base, moving the content to `target` and recomputing slot ranges for the swapped widths.
        mutating func commitPendingSwap(to target: Int) {
            guard let pendingSequence else {
                return
            }
            let lower = min(contentSlotIndex, target)
            let upper = max(contentSlotIndex, target)
            let lowerSlot = slots[lower]
            let upperSlot = slots[upper]
            let widthDelta = upperSlot.range.count - lowerSlot.range.count

            slots[lower] = (
                nodeID: upperSlot.nodeID,
                range: lowerSlot.range.lowerBound ... lowerSlot.range.lowerBound + upperSlot.range.count - 1
            )
            for index in lower + 1 ..< upper {
                let range = slots[index].range
                slots[index].range = range.lowerBound + widthDelta ... range.upperBound + widthDelta
            }
            let upperStart = upperSlot.range.lowerBound + widthDelta
            slots[upper] = (
                nodeID: lowerSlot.nodeID,
                range: upperStart ... upperStart + lowerSlot.range.count - 1
            )

            runningSequence = pendingSequence
            self.pendingSequence = nil
            contentSlotIndex = target
            acceptedSlotIndex = target
        }
    }

    // MARK: - GraphEncoder

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

    /// Adopts the decoded sequence for the outstanding probe so the next extension probe builds on what was committed. A decoded sequence of a different length invalidates the slot ranges, so the extension ends.
    mutating func refreshState(graph _: ChoiceGraph, sequence: ChoiceSequence) {
        guard var state = extensionState else {
            return
        }
        guard state.pendingSequence?.count == sequence.count else {
            extensionState = nil
            return
        }
        state.pendingSequence = sequence
        extensionState = state
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
