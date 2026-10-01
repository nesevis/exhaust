//
//  GraphSwapEncoder+InitialProbe.swift
//  Exhaust
//

// MARK: - Initial Probe

extension GraphSwapEncoder {
    /// Builds the initial swap probe from a permutation scope carrying a full same-shaped sibling group.
    ///
    /// Walks adjacent pairs in position order and returns the first pair whose swap improves shortlex. For groups of three or more siblings, also initializes ``extensionState`` so that ``nextExtensionProbe(into:lastAccepted:)`` can adaptively push the moved content further rightward on success.
    mutating func buildInitialProbe(
        into candidate: inout ChoiceSequence,
        scope: PermutationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ProjectedMutation? {
        let parentNodeID = scope.parentNodeID
        let swappableGroups = scope.swappableGroups
        guard let group = swappableGroups.first,
              group.count >= 2
        else {
            return nil
        }

        // Collect members sorted by position.
        var slots: [(nodeID: Int, range: ClosedRange<Int>)] = []
        for nodeID in group {
            guard let range = graph.nodes[nodeID].positionRange else { return nil }
            slots.append((nodeID: nodeID, range: range))
        }
        slots.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Find the first adjacent pair whose swap improves shortlex.
        for slotIndex in 0 ..< slots.count - 1 {
            let built = sequence.swappingSpans(
                slots[slotIndex].range,
                slots[slotIndex + 1].range
            )
            guard built.shortLexPrecedes(sequence) else { continue }

            // Initialize extension state for groups of three or more.
            if slots.count >= 3 {
                extensionState = ExtensionState(
                    parentNodeID: parentNodeID,
                    slots: slots,
                    runningSequence: sequence,
                    contentSlotIndex: slotIndex,
                    acceptedSlotIndex: slotIndex,
                    step: 1,
                    bisectHi: nil,
                    pendingTargetSlotIndex: slotIndex + 1,
                    pendingSequence: built
                )
            }

            candidate = built
            return .siblingsSwapped(
                parentNodeID: parentNodeID,
                lhs: slots[slotIndex].nodeID,
                rhs: slots[slotIndex + 1].nodeID
            )
        }
        return nil
    }
}

// MARK: - Adaptive Extension

extension GraphSwapEncoder {
    /// Generates the next extension probe or terminates the adaptive search.
    ///
    /// After a successful initial swap moved content from slot A to slot B, the extension tries pushing it further rightward. The pattern is ``find_integer``-style doubling then bisection:
    ///
    /// 1. Try swapping the content at its current slot with the sibling ``step`` positions further right.
    /// 2. On success: update the running sequence, double the step, try again.
    /// 3. On failure: bisect between the last accepted position and the failed target.
    /// 4. When the bisection converges (no untried midpoint), terminate.
    ///
    /// The first call carries feedback for the initial swap, which is the first outstanding probe. Probes are built from ``ExtensionState/runningSequence``, which advances only when a probe is accepted.
    mutating func nextExtensionProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard var state = extensionState,
              let target = state.pendingTargetSlotIndex
        else {
            extensionState = nil
            return nil
        }
        state.pendingTargetSlotIndex = nil
        let isBisecting = state.bisectHi != nil

        if lastAccepted {
            state.commitPendingSwap(to: target)
        } else {
            state.pendingSequence = nil
            guard isBisecting || state.step > 1 else {
                // The initial swap was rejected.
                extensionState = nil
                return nil
            }
            // A rejected doubling probe starts bisection below it; a rejected bisection probe narrows it.
            state.bisectHi = target
        }

        let result = switch (lastAccepted, isBisecting) {
            case (true, false):
                nextDoublingProbe(into: &candidate, state: &state)
            case (true, true), (false, _):
                bisectExtension(into: &candidate, state: &state)
        }
        extensionState = result == nil ? nil : state
        return result
    }

    /// Doubles the step and tries the next target, falling back to bisection when the target overshoots or does not improve shortlex.
    private func nextDoublingProbe(into candidate: inout ChoiceSequence, state: inout ExtensionState) -> EncoderProbe? {
        state.step *= 2
        let nextTarget = state.contentSlotIndex + state.step
        guard nextTarget < state.slots.count else {
            // Doubling overshot — switch to bisecting between current position and end.
            guard state.contentSlotIndex + 1 < state.slots.count else {
                return nil
            }
            state.bisectHi = state.slots.count - 1
            return bisectExtension(into: &candidate, state: &state)
        }

        let built = state.runningSequence.swappingSpans(
            state.slots[state.contentSlotIndex].range,
            state.slots[nextTarget].range
        )
        guard built.shortLexPrecedes(state.runningSequence) else {
            // Swap doesn't improve shortlex — treat as rejection.
            guard state.contentSlotIndex + 1 < nextTarget else {
                return nil
            }
            state.bisectHi = nextTarget
            return bisectExtension(into: &candidate, state: &state)
        }

        return emit(built, target: nextTarget, into: &candidate, state: &state)
    }

    /// Bisects between the last accepted slot and the rejected boundary.
    private func bisectExtension(into candidate: inout ChoiceSequence, state: inout ExtensionState) -> EncoderProbe? {
        guard let highBound = state.bisectHi else {
            return nil
        }

        let lowBound = state.acceptedSlotIndex
        guard lowBound + 1 < highBound else {
            return nil
        }

        let mid = lowBound + (highBound - lowBound) / 2
        let built = state.runningSequence.swappingSpans(
            state.slots[state.contentSlotIndex].range,
            state.slots[mid].range
        )
        guard built.shortLexPrecedes(state.runningSequence) else {
            state.bisectHi = mid
            return bisectExtension(into: &candidate, state: &state)
        }

        return emit(built, target: mid, into: &candidate, state: &state)
    }

    /// Records `built` as the outstanding probe without advancing the base.
    private func emit(
        _ built: ChoiceSequence,
        target: Int,
        into candidate: inout ChoiceSequence,
        state: inout ExtensionState
    ) -> EncoderProbe {
        state.pendingTargetSlotIndex = target
        state.pendingSequence = built
        candidate = built
        return .siblingsSwapped(
            parentNodeID: state.parentNodeID,
            lhs: state.slots[state.contentSlotIndex].nodeID,
            rhs: state.slots[target].nodeID
        )
    }
}
