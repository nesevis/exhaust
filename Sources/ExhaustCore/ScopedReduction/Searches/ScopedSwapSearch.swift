//
//  ScopedSwapSearch.swift
//  Exhaust
//

// MARK: - Swap Search

/// Reorders same-shaped siblings within a parent node for shortlex improvement, then pushes the moved content further rightward.
///
/// The first probe swaps the first adjacent pair whose swap improves shortlex. For groups of two, that is the only probe. For groups of three or more, an accepted swap starts an extension that tries to move the content to its final position in O(log N) probes instead of O(N) sequential swaps: it doubles the distance while swaps are accepted, then bisects between the last accepted slot and the first rejected one. Each probe is a single pairwise swap.
///
/// The search keeps going after an acceptance. It adopts the recovered sequence as the base for the next probe; a recovered sequence of a different length invalidates the slot ranges, so the extension ends.
struct ScopedSwapSearch: ScopedSearch {
    /// The first probe, consumed on the first pull.
    private var initialProbe: (candidate: ChoiceSequence, mutation: EncoderProbe)?

    /// Non-nil when the first probe targets a group of three or more.
    private var extensionState: ExtensionState?

    /// A swap that has been emitted but not yet accepted or rejected.
    private struct PendingSwap {
        let targetSlotIndex: Int
        /// Becomes ``ExtensionState/runningSequence`` only when the probe is accepted.
        var sequence: ChoiceSequence
    }

    /// Mutable state for the rightward extension.
    private struct ExtensionState {
        let parentNodeID: Int
        /// Same-shaped sibling slots sorted by position. Each entry names the node whose content currently occupies the slot and the slot's position range in ``runningSequence``. Same-shaped siblings can differ in width, so ranges are recomputed after every accepted swap.
        var slots: [(nodeID: Int, range: ClosedRange<Int>)]
        /// The sequence as it was after the last accepted swap. Used as the base for building the next extension candidate.
        var runningSequence: ChoiceSequence
        /// Index into ``slots`` of the slot currently holding the content being pushed rightward. Content only moves on acceptance, so this is also the farthest accepted slot.
        var contentSlotIndex: Int
        /// Doubles on success; a failure starts bisection.
        var step: Int
        /// When non-nil, the search is bisecting between ``contentSlotIndex`` and this exclusive bound: a rejected slot, or `slots.count` after doubling overshot the group.
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

    /// Plans the first swap from the scope's first same-shaped group, walking adjacent pairs in position order.
    init(scope: PermutationScope, sequence: ChoiceSequence, graph: ChoiceGraph) {
        initialProbe = nil
        extensionState = nil
        let parentNodeID = scope.parentNodeID
        guard let group = scope.swappableGroups.first,
              group.count >= 2
        else {
            return
        }

        // Collect members sorted by position.
        var slots: [(nodeID: Int, range: ClosedRange<Int>)] = []
        for nodeID in group {
            guard let range = graph.nodes[nodeID].positionRange else {
                return
            }
            slots.append((nodeID: nodeID, range: range))
        }
        slots.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Find the first adjacent pair whose swap improves shortlex.
        for slotIndex in 0 ..< slots.count - 1 {
            let built = sequence.swappingSpans(
                slots[slotIndex].range,
                slots[slotIndex + 1].range
            )
            guard built.shortLexPrecedes(sequence) else {
                continue
            }

            // Initialize extension state for groups of three or more.
            if slots.count >= 3 {
                extensionState = ExtensionState(
                    parentNodeID: parentNodeID,
                    slots: slots,
                    runningSequence: sequence,
                    contentSlotIndex: slotIndex,
                    step: 1,
                    bisectHi: nil,
                    pending: PendingSwap(
                        targetSlotIndex: slotIndex + 1,
                        sequence: built
                    )
                )
            }

            initialProbe = (
                candidate: built,
                mutation: .siblingsSwapped(
                    parentNodeID: parentNodeID,
                    lhs: slots[slotIndex].nodeID,
                    rhs: slots[slotIndex + 1].nodeID
                )
            )
            return
        }
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        if case let .accepted(recovered) = feedback {
            adoptRecovered(recovered)
        }

        if let initial = initialProbe {
            initialProbe = nil
            buffer = initial.candidate
            return .written(mutation: initial.mutation, admission: .standard)
        }

        if extensionState != nil {
            return nextExtensionProbe(into: &buffer, lastAccepted: feedback.isAccepted)
                .map { .written(mutation: $0, admission: .standard) }
        }

        return nil
    }

    // MARK: - Helpers

    /// Adopts the recovered sequence for the outstanding probe so the next extension probe builds on what was committed. A recovered sequence of a different length invalidates the slot ranges, so the extension ends.
    ///
    /// A same-length recovery is assumed to keep sibling widths. If a bind redistributes entries anyway, later probes misalign and cost rejected probes, but the ordering check still admits only genuine reductions.
    private mutating func adoptRecovered(_ sequence: ChoiceSequence) {
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

    /// Generates the next extension probe or ends the extension.
    ///
    /// 1. Try swapping the content at its current slot with the sibling ``ExtensionState/step`` positions further right.
    /// 2. On success: update the running sequence, double the step, try again.
    /// 3. On failure: bisect between the last accepted position and the failed target.
    /// 4. When the bisection converges (no untried midpoint), stop.
    ///
    /// The first call carries feedback for the initial swap, which is the first outstanding probe. Probes are built from ``ExtensionState/runningSequence``, which advances only when a probe is accepted.
    private mutating func nextExtensionProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard var state = extensionState,
              let pending = state.pending
        else {
            extensionState = nil
            return nil
        }
        state.pending = nil
        let isBisecting = state.bisectHi != nil

        if lastAccepted {
            state.commit(pending)
        } else {
            guard isBisecting || state.step > 1 else {
                // The initial swap was rejected.
                extensionState = nil
                return nil
            }
            // A rejected doubling probe starts bisection below it; a rejected bisection probe narrows it.
            state.bisectHi = pending.targetSlotIndex
        }

        let result = switch (lastAccepted, isBisecting) {
            case (true, false):
                Self.nextDoublingProbe(into: &candidate, state: &state)
            case (true, true), (false, _):
                Self.bisectExtension(into: &candidate, state: &state)
        }
        extensionState = result == nil ? nil : state
        return result
    }

    /// Doubles the step and tries the next target, falling back to bisection when the target overshoots or does not improve shortlex.
    private static func nextDoublingProbe(into candidate: inout ChoiceSequence, state: inout ExtensionState) -> EncoderProbe? {
        state.step *= 2
        let nextTarget = state.contentSlotIndex + state.step
        guard nextTarget < state.slots.count else {
            // Doubling overshot, so bisect between the current position and the end. The bound is one past the last slot, which has not been tried.
            guard state.contentSlotIndex + 1 < state.slots.count else {
                return nil
            }
            state.bisectHi = state.slots.count
            return bisectExtension(into: &candidate, state: &state)
        }

        let built = state.runningSequence.swappingSpans(
            state.slots[state.contentSlotIndex].range,
            state.slots[nextTarget].range
        )
        guard built.shortLexPrecedes(state.runningSequence) else {
            // A swap that does not improve shortlex counts as a rejection.
            guard state.contentSlotIndex + 1 < nextTarget else {
                return nil
            }
            state.bisectHi = nextTarget
            return bisectExtension(into: &candidate, state: &state)
        }

        return emit(built, target: nextTarget, into: &candidate, state: &state)
    }

    /// Bisects between the last accepted slot and the rejected boundary.
    private static func bisectExtension(into candidate: inout ChoiceSequence, state: inout ExtensionState) -> EncoderProbe? {
        guard let highBound = state.bisectHi else {
            return nil
        }

        let lowBound = state.contentSlotIndex
        guard lowBound + 1 < highBound else {
            return nil
        }

        let midpoint = lowBound + (highBound - lowBound) / 2
        let built = state.runningSequence.swappingSpans(
            state.slots[state.contentSlotIndex].range,
            state.slots[midpoint].range
        )
        guard built.shortLexPrecedes(state.runningSequence) else {
            state.bisectHi = midpoint
            return bisectExtension(into: &candidate, state: &state)
        }

        return emit(built, target: midpoint, into: &candidate, state: &state)
    }

    /// Records `built` as the outstanding probe without advancing the base.
    private static func emit(
        _ built: ChoiceSequence,
        target: Int,
        into candidate: inout ChoiceSequence,
        state: inout ExtensionState
    ) -> EncoderProbe {
        state.pending = PendingSwap(
            targetSlotIndex: target,
            sequence: built
        )
        candidate = built
        return .siblingsSwapped(
            parentNodeID: state.parentNodeID,
            lhs: state.slots[state.contentSlotIndex].nodeID,
            rhs: state.slots[target].nodeID
        )
    }
}
