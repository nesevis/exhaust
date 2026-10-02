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

    /// The extension keeps pushing content rightward after an accepted swap, so the session must survive acceptance. ``refreshState(graph:sequence:)`` adopts the committed sequence as the base for the next extension probe.
    let acceptanceHandling: AcceptanceHandling = .refreshAndIdle

    // MARK: - State

    /// The initial mutation built at ``start(scope:)``. Consumed on the first ``nextProbe(into:lastAccepted:)`` call.
    private var initialProbe: EncoderProbe?

    /// The candidate sequence for the initial probe, stored alongside ``initialProbe``.
    private var initialProbeCandidate: ChoiceSequence?

    /// Adaptive extension state. Non-nil when the initial probe targeted a group of three or more and extension is viable. Set at ``start(scope:)`` alongside the initial probe.
    var extensionState: ExtensionState?

    /// A swap that has been emitted but not yet accepted or rejected.
    struct PendingSwap {
        let targetSlotIndex: Int
        /// Becomes ``ExtensionState/runningSequence`` only when the probe is accepted.
        var sequence: ChoiceSequence
    }

    /// Mutable state for the adaptive rightward extension.
    struct ExtensionState {
        let parentNodeID: Int
        /// Same-shaped sibling slots sorted by position. Each entry names the node whose content currently occupies the slot and the slot's position range in ``runningSequence``. Same-shaped siblings can differ in width, so ranges are recomputed after every accepted swap.
        var slots: [(nodeID: Int, range: ClosedRange<Int>)]
        /// The sequence as it was after the last accepted swap. Used as the base for building the next extension candidate.
        var runningSequence: ChoiceSequence
        /// Index into ``slots`` of the slot currently holding the content being pushed rightward. Content only moves on acceptance, so this is also the farthest accepted slot.
        var contentSlotIndex: Int
        /// Adaptive step size: doubles on success, triggers bisection on failure.
        var step: Int
        /// When non-nil, the encoder is bisecting between ``contentSlotIndex`` and ``bisectHi`` (rejected).
        var bisectHi: Int?
        /// The emitted probe awaiting feedback, or nil when no probe is outstanding. The initial swap is the first outstanding probe.
        var pending: PendingSwap?

        /// Adopts an accepted probe as the new base, moving the content to its target and recomputing slot ranges for the swapped widths.
        mutating func commit(_ accepted: PendingSwap) {
            let target = accepted.targetSlotIndex
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

            runningSequence = accepted.sequence
            contentSlotIndex = target
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
    ///
    /// A same-length decode is assumed to keep sibling widths. If a bind redistributes entries anyway, later probes misalign and cost rejected probes, but the decoder's shortlex gate still admits only genuine reductions.
    mutating func refreshState(graph _: ChoiceGraph, sequence: ChoiceSequence) {
        guard var state = extensionState else {
            return
        }
        guard state.pending?.sequence.count == sequence.count else {
            extensionState = nil
            return
        }
        state.pending?.sequence = sequence
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
