//
//  GraphStructuralEncoder+Swap.swift
//  Exhaust
//

// MARK: - Initial Probe

extension GraphSwapEncoder {
    /// Builds the initial swap probe from a permutation scope carrying a full same-shaped sibling group.
    ///
    /// Walks adjacent pairs in position order and returns the first pair whose swap improves shortlex. For groups of three or more siblings, also initializes ``extensionState`` so that ``nextExtensionProbe(lastAccepted:)`` can adaptively push the moved content further rightward on success.
    mutating func buildInitialProbe(
        scope: PermutationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> EncoderProbe? {
        guard case let .siblingPermutation(permutationScope) = scope else { return nil }
        guard let group = permutationScope.swappableGroups.first,
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
            let candidate = Self.buildSwapCandidate(
                sequence: sequence,
                rangeA: slots[slotIndex].range,
                rangeB: slots[slotIndex + 1].range
            )
            guard candidate.shortLexPrecedes(sequence) else { continue }

            // Initialize extension state for groups of three or more.
            if slots.count >= 3 {
                extensionState = ExtensionState(
                    parentNodeID: permutationScope.parentNodeID,
                    slots: slots,
                    runningSequence: candidate,
                    contentSlotIndex: slotIndex + 1,
                    acceptedSlotIndex: slotIndex + 1,
                    step: 1,
                    bisectHi: nil
                )
            }

            return EncoderProbe(
                candidate: candidate,
                mutation: .siblingsSwapped(
                    parentNodeID: permutationScope.parentNodeID,
                    idA: slots[slotIndex].nodeID,
                    idB: slots[slotIndex + 1].nodeID
                )
            )
        }
        return nil
    }

    /// Builds a candidate sequence by exchanging the entries at two position ranges.
    static func buildSwapCandidate(
        sequence: ChoiceSequence,
        rangeA: ClosedRange<Int>,
        rangeB: ClosedRange<Int>
    ) -> ChoiceSequence {
        let (first, second) = rangeA.lowerBound < rangeB.lowerBound
            ? (rangeA, rangeB)
            : (rangeB, rangeA)

        let entriesFirst = Array(sequence[first.lowerBound ... first.upperBound])
        let entriesSecond = Array(sequence[second.lowerBound ... second.upperBound])

        var result = sequence
        result.replaceSubrange(second.lowerBound ... second.upperBound, with: entriesFirst)
        result.replaceSubrange(first.lowerBound ... first.upperBound, with: entriesSecond)
        return result
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
    mutating func nextExtensionProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard var state = extensionState else { return nil }

        if lastAccepted == false {
            // Previous extension probe rejected.
            if state.bisectHi != nil {
                let result = bisectExtension(state: &state)
                extensionState = result == nil ? nil : state
                return result
            }
            if state.step <= 1 {
                // First extension rejected at step 1 — no room.
                extensionState = nil
                return nil
            }
            // Switch from doubling to bisecting.
            let failedTarget = min(state.contentSlotIndex + state.step, state.slots.count - 1)
            state.bisectHi = failedTarget
            let result = bisectExtension(state: &state)
            extensionState = result == nil ? nil : state
            return result
        }

        // Previous extension probe accepted. Update state and push further.
        let targetSlotIndex = state.bisectHi != nil
            ? (state.acceptedSlotIndex + (state.bisectHi! - state.acceptedSlotIndex) / 2)
            : min(state.contentSlotIndex + state.step, state.slots.count - 1)

        state.acceptedSlotIndex = targetSlotIndex
        state.contentSlotIndex = targetSlotIndex

        if state.bisectHi != nil {
            let result = bisectExtension(state: &state)
            extensionState = result == nil ? nil : state
            return result
        }

        // Doubling phase: double the step and try the next target.
        state.step *= 2
        let nextTarget = state.contentSlotIndex + state.step
        guard nextTarget < state.slots.count else {
            // Doubling overshot — switch to bisecting between current position and end.
            if state.contentSlotIndex + 1 < state.slots.count {
                state.bisectHi = state.slots.count - 1
                let result = bisectExtension(state: &state)
                extensionState = result == nil ? nil : state
                return result
            }
            extensionState = nil
            return nil
        }

        let candidate = Self.buildSwapCandidate(
            sequence: state.runningSequence,
            rangeA: state.slots[state.contentSlotIndex].range,
            rangeB: state.slots[nextTarget].range
        )
        guard candidate.shortLexPrecedes(state.runningSequence) else {
            // Swap doesn't improve shortlex — treat as rejection.
            if state.contentSlotIndex + 1 < nextTarget {
                state.bisectHi = nextTarget
                let result = bisectExtension(state: &state)
                extensionState = result == nil ? nil : state
                return result
            }
            extensionState = nil
            return nil
        }

        state.runningSequence = candidate
        extensionState = state

        return EncoderProbe(
            candidate: candidate,
            mutation: .siblingsSwapped(
                parentNodeID: state.parentNodeID,
                idA: state.slots[state.contentSlotIndex].nodeID,
                idB: state.slots[nextTarget].nodeID
            )
        )
    }

    /// Bisects between the last accepted slot and the rejected boundary.
    private mutating func bisectExtension(state: inout ExtensionState) -> EncoderProbe? {
        guard let highBound = state.bisectHi else { return nil }

        let lowBound = state.acceptedSlotIndex
        guard lowBound + 1 < highBound else {
            return nil
        }

        let mid = lowBound + (highBound - lowBound) / 2
        let candidate = Self.buildSwapCandidate(
            sequence: state.runningSequence,
            rangeA: state.slots[state.contentSlotIndex].range,
            rangeB: state.slots[mid].range
        )
        guard candidate.shortLexPrecedes(state.runningSequence) else {
            state.bisectHi = mid
            return bisectExtension(state: &state)
        }

        state.runningSequence = candidate

        return EncoderProbe(
            candidate: candidate,
            mutation: .siblingsSwapped(
                parentNodeID: state.parentNodeID,
                idA: state.slots[state.contentSlotIndex].nodeID,
                idB: state.slots[mid].nodeID
            )
        )
    }
}
