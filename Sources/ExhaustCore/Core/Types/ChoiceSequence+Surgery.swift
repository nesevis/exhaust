// Candidate writers over flattened choice sequences.
//
// Every writer is a pure function of the receiver: positions and movement direction come from the caller, no tree or graph is consulted, and acceptance policy (shortlex gating, delta bounds) is the caller's.

/// What ``ChoiceSequence/shiftingGroup(entries:tag:shiftUpward:delta:usesFloatingSteps:policy:)`` does with a member the delta cannot move.
package enum GroupShiftPolicy {
    /// Leave it and shift the rest. The reducer's probe: it validates every candidate on shortlex order and a property re-run, so a partial shift that breaks a relationship is rejected there.
    case skipUnmovable

    /// Abort the candidate. The mutator's contract: it has no validator, and the operator exists to preserve agreement across the group.
    case requireWholeGroup
}

package extension ChoiceSequence {
    // MARK: - Span Writers

    /// Builds a candidate sequence by exchanging the entries at two position ranges.
    func swappingSpans(
        _ rangeA: ClosedRange<Int>,
        _ rangeB: ClosedRange<Int>
    ) -> ChoiceSequence {
        let (first, second) = rangeA.lowerBound < rangeB.lowerBound
            ? (rangeA, rangeB)
            : (rangeB, rangeA)

        let entriesFirst = Array(self[first.lowerBound ... first.upperBound])
        let entriesSecond = Array(self[second.lowerBound ... second.upperBound])

        var result = self
        result.replaceSubrange(second.lowerBound ... second.upperBound, with: entriesFirst)
        result.replaceSubrange(first.lowerBound ... first.upperBound, with: entriesSecond)
        return result
    }

    /// Builds a candidate sequence by writing the entries at `source` over the entries at `target`, leaving `source` unchanged.
    ///
    /// The one-directional variant of ``swappingSpans(_:_:)``: after the copy both ranges hold the source content. Spans of different lengths shift every position after `target`, so the caller's cached positions for the result are stale past `target.lowerBound`.
    func copyingSpan(
        from source: ClosedRange<Int>,
        onto target: ClosedRange<Int>
    ) -> ChoiceSequence {
        let entries = Array(self[source.lowerBound ... source.upperBound])
        var result = self
        result.replaceSubrange(target.lowerBound ... target.upperBound, with: entries)
        return result
    }

    /// Reconstructs a sequence with sibling spans rearranged according to the given permutation.
    ///
    /// `ranges` are the spans' full extents in position order; `permutation[destination]` names the range whose content lands at `destination`. Content between adjacent ranges is preserved in place.
    func permutingSpans(
        ranges: [ClosedRange<Int>],
        permutation: [Int]
    ) -> ChoiceSequence {
        let slices = ranges.map { Array(self[$0]) }
        let spanStart = ranges[0].lowerBound
        let spanEnd = ranges[ranges.count - 1].upperBound

        var rebuilt = ContiguousArray(self[..<spanStart])
        var index = 0
        while index < ranges.count {
            if index > 0 {
                let gapStart = ranges[index - 1].upperBound + 1
                let gapEnd = ranges[index].lowerBound
                if gapStart < gapEnd {
                    rebuilt.append(contentsOf: self[gapStart ..< gapEnd])
                }
            }
            rebuilt.append(contentsOf: slices[permutation[index]])
            index += 1
        }
        if spanEnd + 1 < count {
            rebuilt.append(contentsOf: self[(spanEnd + 1)...])
        }

        return ChoiceSequence(rebuilt)
    }

    /// Builds a candidate sequence by writing a span from a different sequence over the entries at `target`.
    ///
    /// The cross-sequence variant of ``copyingSpan(from:onto:)``. `donorRange` must address `donor`; spans of different lengths shift every position after `target`.
    func graftingSpan(
        from donor: ChoiceSequence,
        at donorRange: ClosedRange<Int>,
        onto target: ClosedRange<Int>
    ) -> ChoiceSequence {
        var result = self
        result.replaceSubrange(
            target.lowerBound ... target.upperBound,
            with: donor[donorRange.lowerBound ... donorRange.upperBound]
        )
        return result
    }

    // MARK: - Value Writers

    /// Builds a candidate sequence by shifting every entry of a same-tag group by one shared delta.
    ///
    /// A member the delta cannot move is a nil value, a value whose shifted result escapes an explicit range, or a value the delta leaves shortlex-equal. `policy` decides what that costs. A float that fails to encode or an integer shift that would wrap `UInt64` aborts under either policy.
    ///
    /// - Parameters:
    ///   - entries: The group's positions with their original entries. Positions must address the receiver.
    ///   - policy: What to do with a member the delta cannot move.
    /// - Returns: The candidate and the shortlex order of the first changed entry against its original, or nil when no entry changed or the shift aborted.
    func shiftingGroup(
        entries: [(index: Int, entry: ChoiceSequenceValue)],
        tag: TypeTag,
        shiftUpward: Bool,
        delta: UInt64,
        usesFloatingSteps: Bool,
        policy: GroupShiftPolicy
    ) -> (candidate: ChoiceSequence, firstDifferenceOrder: ShortlexOrder)? {
        guard delta > 0 else { return nil }

        var candidate = self
        var firstDifferenceOrder: ShortlexOrder = .eq
        var hasDifference = false

        var entryOffset = 0
        while entryOffset < entries.count {
            let pair = entries[entryOffset]
            let position = pair.index
            let originalEntry = pair.entry
            guard let value = originalEntry.value else {
                if policy == .requireWholeGroup { return nil }
                entryOffset += 1
                continue
            }

            let newChoice: ChoiceValue
            if usesFloatingSteps {
                let currentFloat = value.choice.decodedDoubleValue
                let signedDelta = shiftUpward ? Double(delta) : -Double(delta)
                let candidateFloat = currentFloat + signedDelta
                guard let floatChoice = tag.floatingChoice(
                    from: candidateFloat
                ) else { return nil }
                newChoice = floatChoice
            } else {
                guard shiftUpward
                    ? UInt64.max - delta >= value.choice.bitPattern64
                    : value.choice.bitPattern64 >= delta
                else { return nil }

                let newBitPattern = shiftUpward
                    ? value.choice.bitPattern64 + delta
                    : value.choice.bitPattern64 - delta
                newChoice = ChoiceValue(
                    tag.makeConvertible(bitPattern64: newBitPattern),
                    tag: tag
                )
            }

            guard value.isRangeExplicit == false || newChoice.fits(in: value.validRange) else {
                if policy == .requireWholeGroup { return nil }
                entryOffset += 1
                continue
            }

            let newEntry = ChoiceSequenceValue.value(.init(
                choice: newChoice,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
            let order = newEntry.shortLexCompare(originalEntry)
            guard order != .eq else {
                if policy == .requireWholeGroup { return nil }
                entryOffset += 1
                continue
            }

            if hasDifference == false {
                hasDifference = true
                firstDifferenceOrder = order
            }
            candidate[position] = newEntry
            entryOffset += 1
        }

        guard hasDifference else { return nil }
        return (candidate, firstDifferenceOrder)
    }
}
