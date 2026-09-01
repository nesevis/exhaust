// Candidate writers over flattened choice sequences.
//
// Every writer is a pure function of the receiver: positions and movement direction come from the caller, no tree or graph is consulted, and acceptance policy (shortlex gating, delta bounds) is the caller's.

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
    /// Entries the shift cannot change are skipped rather than failing the whole candidate: nil values, values whose shifted result escapes an explicit range, and values the delta leaves shortlex-equal. A float that fails to encode or an integer shift that would wrap `UInt64` aborts the candidate entirely, because a partial group shift is not the move the caller asked for.
    ///
    /// - Parameter entries: The group's positions with their original entries. Positions must address the receiver.
    /// - Returns: The candidate and the shortlex order of the first changed entry against its original, or nil when no entry changed or the shift aborted.
    func shiftingGroup(
        entries: [(index: Int, entry: ChoiceSequenceValue)],
        tag: TypeTag,
        shiftUpward: Bool,
        delta: UInt64,
        usesFloatingSteps: Bool
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

            // Skip values that fall outside an explicit range.
            guard value.isRangeExplicit == false || newChoice.fits(in: value.validRange) else {
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

    /// Builds a candidate sequence by transferring `delta` units of magnitude from a source entry to a sink entry, holding the pair's sum.
    ///
    /// For pairs with a ``MixedRedistributionContext`` (cross-type or floating-point), uses rational arithmetic with a common denominator; the context carries the movement direction and `sourceMovesUpward` is ignored. For same-tag integer pairs, operates in UInt64 bit-pattern space — modular wraparound when the sink's declared domain equals its natural type width, validation-with-rejection when the sink has an explicit narrow range.
    ///
    /// - Important: The caller bounds `delta` so the source stays inside its own domain; the modular path validates only the sink.
    func transferringMagnitude(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        delta: UInt64,
        sourceMovesUpward: Bool,
        mixedContext: MixedRedistributionContext?
    ) -> ChoiceSequence? {
        guard delta > 0 else { return nil }

        let sourceEntry = self[sourceIndex]
        let sinkEntry = self[sinkIndex]
        guard let sourceValue = sourceEntry.value else { return nil }
        guard let sinkValue = sinkEntry.value else { return nil }

        // Mixed/rational path for cross-type or float pairs. Direction lives in the context, not the parameter.
        if let context = mixedContext {
            guard let (newSourceChoice, newSinkChoice) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
                sourceChoice: sourceValue.choice,
                sinkChoice: sinkValue.choice,
                delta: delta,
                context: context
            ) else { return nil }

            // Validate against valid ranges.
            if sourceValue.isRangeExplicit,
               newSourceChoice.fits(in: sourceValue.validRange) == false { return nil }
            if sinkValue.isRangeExplicit,
               newSinkChoice.fits(in: sinkValue.validRange) == false { return nil }

            var candidate = self
            candidate[sourceIndex] = .value(.init(
                choice: newSourceChoice,
                validRange: sourceValue.validRange,
                isRangeExplicit: sourceValue.isRangeExplicit
            ))
            candidate[sinkIndex] = .value(.init(
                choice: newSinkChoice,
                validRange: sinkValue.validRange,
                isRangeExplicit: sinkValue.isRangeExplicit
            ))
            return candidate
        }

        // Same-tag integer path.
        //
        // The gate is on the sink, not the source. The caller keeps the source's movement inside its own domain (see the Important callout above), so its new bit pattern never leaves the source's valid range. The sink is the side that can escape its valid range as it absorbs the opposing delta, so the sink is the side that determines which sub-path we take.
        //
        // When the sink's declared domain equals the natural type width, we use bit-pattern modular arithmetic with a width-aware mask. This matches the wrapping arithmetic (`&+`/`&-`) the property under test likely uses for the same type and lets redistribution reach boundary counterexamples like `(Int16.min, -1)` that semantic-space arithmetic would reject as overflow.
        //
        // When the sink carries an explicit narrow range, we still operate in UInt64 bit-pattern space (signed types are biased via the
        // `signBitMask` XOR in their `BitPatternConvertible` conformance, so additive arithmetic in biased space matches semantic arithmetic), but we use overflow-checked operations and reject — rather than wrap — any candidate that lands outside the sink's `validRange` or the type's natural bounds.
        let sourceBitPattern = sourceValue.choice.bitPattern64
        let sinkBitPattern = sinkValue.choice.bitPattern64

        if sinkValue.allowsModularArithmetic {
            let mask = sinkValue.choice.tag.bitPatternRange.upperBound
            let newSourceBitPattern: UInt64
            let newSinkBitPattern: UInt64
            if sourceMovesUpward {
                newSourceBitPattern = (sourceBitPattern &+ delta) & mask
                newSinkBitPattern = (sinkBitPattern &- delta) & mask
            } else {
                newSourceBitPattern = (sourceBitPattern &- delta) & mask
                newSinkBitPattern = (sinkBitPattern &+ delta) & mask
            }

            var candidate = self
            candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBitPattern)
            candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBitPattern)
            return candidate
        }

        // Narrow-sink fallback: UInt64 bit-pattern arithmetic with explicit bounds enforcement.
        let newSourceBitPattern: UInt64
        let newSinkBitPattern: UInt64
        if sourceMovesUpward {
            // Source moves up, sink moves down.
            let (sourceSum, sourceOverflow) = sourceBitPattern.addingReportingOverflow(delta)
            guard sourceOverflow == false else { return nil }
            newSourceBitPattern = sourceSum
            guard sinkBitPattern >= delta else { return nil }
            newSinkBitPattern = sinkBitPattern - delta
        } else {
            // Source moves down, sink moves up.
            // The reducer bounds delta to the source's distance above its reduction target, so this subtraction cannot underflow there. Defensive guard against a stale or out-of-range caller delta.
            guard sourceBitPattern >= delta else { return nil }
            newSourceBitPattern = sourceBitPattern - delta
            let (sinkSum, sinkOverflow) = sinkBitPattern.addingReportingOverflow(delta)
            guard sinkOverflow == false else { return nil }
            newSinkBitPattern = sinkSum
        }

        // Enforce natural type bounds via `tag.bitPatternRange`.
        guard sourceTag.bitPatternRange.contains(newSourceBitPattern),
              sinkValue.choice.tag.bitPatternRange.contains(newSinkBitPattern)
        else {
            return nil
        }

        // Enforce explicit `validRange` so candidates stay within the user's declared domain.
        if sourceValue.isRangeExplicit,
           let range = sourceValue.validRange,
           range.contains(newSourceBitPattern) == false
        {
            return nil
        }
        if sinkValue.isRangeExplicit,
           let range = sinkValue.validRange,
           range.contains(newSinkBitPattern) == false
        {
            return nil
        }

        var candidate = self
        candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBitPattern)
        candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBitPattern)
        return candidate
    }
}
