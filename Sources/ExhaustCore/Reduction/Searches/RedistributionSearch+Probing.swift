//
//  RedistributionSearch+Probing.swift
//  Exhaust
//

// MARK: - Redistribution

extension RedistributionSearch {
    mutating func startRedistribution(
        scope: RedistributionScope,
        graph: ChoiceGraph
    ) {
        startRedistribution(cursor: scope.pairCursor(), graph: graph)
    }

    /// Accepts any complete pair stream so ranking and bounded retention are independent of domain preparation.
    mutating func startRedistribution<Cursor: ScopeCursor>(cursor initialCursor: Cursor, graph: ChoiceGraph) where Cursor.Scope == RedistributionPair {
        // Every edit changes two values and leaves structure intact, so ranking reads at most four positions rather than copying or scanning the baseline. Keeping a sorted prefix bounds setup storage even when the query supplies many more pairs than the probe budget permits.
        var rankedPairs = BoundedSortedBuffer<RankedPair>(limit: maxPairs)
        var cursor = initialCursor
        while let scopePair = cursor.next() {
            guard let pair = preparePair(scopePair, graph: graph) else {
                continue
            }
            let edit = redistributionEdit(
                sourceIndex: pair.sourceIndex,
                sinkIndex: pair.sinkIndex,
                sourceTag: pair.sourceTag,
                delta: pair.maxDelta,
                mixedContext: pair.mixedContext
            )
            let ranked = RankedPair(pair: pair, edit: edit)
            rankedPairs.insert(ranked) { first, second in
                first.precedes(second, sequence: valueState.sequence)
            }
        }
        guard rankedPairs.elements.isEmpty == false else {
            return
        }
        let pairs = rankedPairs.elements.map(\.pair)
        for pair in pairs {
            valueState.registerLeaf(nodeID: pair.scopePair.source.nodeID, mayReshape: pair.scopePair.source.mayReshapeOnAcceptance, graph: graph)
            valueState.registerLeaf(nodeID: pair.scopePair.sink.nodeID, mayReshape: pair.scopePair.sink.mayReshapeOnAcceptance, graph: graph)
        }

        mode = .active(RedistributionState(
            pairs: pairs,
            pairIndex: 0,
            stepper: nil,
            didEmitCandidate: false,
            triedFullDelta: false,
            acceptedPairIndices: [],
            passCount: 0,
            activePairIndices: nil
        ))
    }

    /// Searches each pair in turn: a full-delta probe that moves the source to its target, then binary search on the transfer delta. Once every pair is done, replays the pairs that accepted, up to ``maxPasses`` passes.
    func nextRedistributionProbe(
        state: inout RedistributionState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.pairIndex < state.pairs.count {
            // Skip pairs not in the active set (on subsequent passes, only re-evaluate pairs that had accepted probes).
            if let active = state.activePairIndices,
               active.contains(state.pairIndex) == false
            {
                state.pairIndex += 1
                continue
            }

            let pair = state.pairs[state.pairIndex]

            if state.stepper == nil {
                // Read the maximum delta from the current sequence, because earlier pairs' acceptances may have moved the source.
                let (currentMax, freshContext) = currentMaxDelta(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    usesMixed: pair.mixedContext != nil
                )
                guard currentMax > 0 else {
                    state.pairIndex += 1
                    continue
                }

                // Try full delta first (zero the source completely).
                if state.triedFullDelta == false {
                    state.triedFullDelta = true
                    if let candidate = buildRedistributionCandidate(
                        sourceIndex: pair.sourceIndex,
                        sinkIndex: pair.sinkIndex,
                        sourceTag: pair.sourceTag,
                        delta: currentMax,
                        mixedContext: freshContext
                    ) {
                        state.didEmitCandidate = true
                        return candidate
                    }
                }

                // Binary search on the delta.
                state.stepper = BinarySearchStepper(
                    lo: 0,
                    hi: currentMax,
                    direction: .findLargest
                )
                state.didEmitCandidate = false

                guard let firstDelta = state.stepper?.start() else {
                    state.pairIndex += 1
                    state.stepper = nil
                    continue
                }

                if let candidate = buildRedistributionCandidate(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    sourceTag: pair.sourceTag,
                    delta: firstDelta,
                    mixedContext: freshContext
                ) {
                    state.didEmitCandidate = true
                    return candidate
                }
                // The first delta built no candidate, so advance the stepper.
            }

            let feedback = state.didEmitCandidate ? lastAccepted : false
            state.didEmitCandidate = false

            // An accepted full delta put the source at its target, so the pair needs no binary search.
            if feedback, state.stepper == nil {
                state.pairIndex += 1
                state.triedFullDelta = false
                continue
            }

            if let nextDelta = state.stepper?.advance(lastAccepted: feedback) {
                // Rebuild the context for each probe, because acceptances move the values it scales.
                let (_, freshContext) = currentMaxDelta(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    usesMixed: pair.mixedContext != nil
                )
                if let candidate = buildRedistributionCandidate(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    sourceTag: pair.sourceTag,
                    delta: nextDelta,
                    mixedContext: freshContext
                ) {
                    state.didEmitCandidate = true
                    return candidate
                }
                continue
            }

            // Stepper converged: move to the next pair.
            state.stepper = nil
            state.pairIndex += 1
            state.triedFullDelta = false
        }

        // All pairs done. Another pass replays only the pairs that accepted, so pairs that cannot move do not spend O(pairs × log(maxDelta)) probes again.
        state.passCount += 1
        if state.acceptedPairIndices.isEmpty == false, state.passCount < maxPasses {
            state.activePairIndices = state.acceptedPairIndices
            state.acceptedPairIndices = []
            state.pairIndex = 0
            state.triedFullDelta = false
            state.stepper = nil
            return nextRedistributionProbe(state: &state, lastAccepted: false)
        }

        return nil
    }

    /// Computes the current maxDelta for a pair, accounting for whether it uses bit-pattern or rational-mixed math.
    func currentMaxDelta(
        sourceIndex: Int,
        sinkIndex: Int,
        usesMixed: Bool
    ) -> (maxDelta: UInt64, mixedContext: MixedRedistributionContext?) {
        guard let sourceValue = valueState.sequence[sourceIndex].value else {
            return (0, nil)
        }

        if usesMixed {
            guard let sinkValue = valueState.sequence[sinkIndex].value else {
                return (0, nil)
            }
            guard let context = Self.makeMixedRedistributionContext(
                sourceChoice: sourceValue.choice,
                sinkChoice: sinkValue.choice,
                sourceValidRange: sourceValue.validRange,
                sourceIsRangeExplicit: sourceValue.isRangeExplicit
            ) else {
                return (0, nil)
            }
            return (context.distanceInSteps, context)
        }

        // Same-tag integer: bit-pattern distance.
        let sourceBitPattern = sourceValue.choice.bitPattern64
        let targetBitPattern = sourceValue.choice.reductionTarget(in: sourceValue.validRange)
        let distance = sourceBitPattern.absoluteDifference(targetBitPattern)
        return (distance, nil)
    }

    /// Builds a redistribution candidate by transferring `delta` units from source to sink.
    ///
    /// A pair with a ``MixedRedistributionContext`` (cross-type or floating-point) uses rational arithmetic over a common denominator. A same-tag integer pair works in `UInt64` bit-pattern space: modular arithmetic when the sink's domain is its full type width, and checked arithmetic that rejects out-of-range results when the sink has a narrower explicit range.
    func buildRedistributionCandidate(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        delta: UInt64,
        mixedContext: MixedRedistributionContext?
    ) -> ChoiceSequence? {
        guard let edit = redistributionEdit(
            sourceIndex: sourceIndex,
            sinkIndex: sinkIndex,
            sourceTag: sourceTag,
            delta: delta,
            mixedContext: mixedContext
        ) else {
            return nil
        }
        return edit.applying(to: valueState.sequence)
    }

    /// Validates a transfer without materializing the baseline, so setup can rank an unbounded pair set with bounded storage.
    func redistributionEdit(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        delta: UInt64,
        mixedContext: MixedRedistributionContext?
    ) -> RedistributionEdit? {
        guard delta > 0 else {
            return nil
        }

        let sourceEntry = valueState.sequence[sourceIndex]
        let sinkEntry = valueState.sequence[sinkIndex]
        guard let sourceValue = sourceEntry.value else {
            return nil
        }
        guard let sinkValue = sinkEntry.value else {
            return nil
        }

        // Mixed/rational path for cross-type or float pairs.
        if let context = mixedContext {
            guard let (newSourceChoice, newSinkChoice) = Self.mixedRedistributedPairChoices(
                sourceChoice: sourceValue.choice,
                sinkChoice: sinkValue.choice,
                delta: delta,
                context: context
            ) else {
                return nil
            }

            // Validate against valid ranges.
            if sourceValue.isRangeExplicit,
               newSourceChoice.fits(in: sourceValue.validRange) == false
            {
                return nil
            }
            if sinkValue.isRangeExplicit,
               newSinkChoice.fits(in: sinkValue.validRange) == false
            {
                return nil
            }

            let newSourceEntry: ChoiceSequenceValue = .value(.init(
                choice: newSourceChoice,
                validRange: sourceValue.validRange,
                isRangeExplicit: sourceValue.isRangeExplicit
            ))
            let newSinkEntry: ChoiceSequenceValue = .value(.init(
                choice: newSinkChoice,
                validRange: sinkValue.validRange,
                isRangeExplicit: sinkValue.isRangeExplicit
            ))
            return RedistributionEdit(sourceIndex: sourceIndex, sinkIndex: sinkIndex, sourceEntry: newSourceEntry, sinkEntry: newSinkEntry)
        }

        // Same-tag integer path.
        //
        // The sink decides the arithmetic. The source moves toward its own target, so it stays between its current value and that target and never leaves its range. The sink absorbs the opposite delta and can leave its range.
        //
        // A sink whose domain is its full type width uses modular arithmetic masked to that width. This matches the wrapping arithmetic (`&+`, `&-`) the property likely uses, and reaches boundary counterexamples such as `(Int16.min, -1)` that semantic arithmetic would reject as overflow.
        //
        // A sink with a narrower explicit range uses checked arithmetic in the same bit-pattern space, and rejects any candidate outside the sink's range or its type's bounds. Signed bit patterns are biased by the sign-bit XOR in `BitPatternConvertible`, so addition on bit patterns matches addition on values.
        let sourceBitPattern = sourceValue.choice.bitPattern64
        let sinkBitPattern = sinkValue.choice.bitPattern64
        let targetBitPattern = sourceValue.choice.reductionTarget(in: sourceValue.validRange)

        if sinkValue.allowsModularArithmetic {
            let mask = sinkValue.choice.tag.bitPatternRange.upperBound
            let (newSourceBitPattern, newSinkBitPattern) = switch sourceBitPattern > targetBitPattern {
                case true:
                    ((sourceBitPattern &- delta) & mask, (sinkBitPattern &+ delta) & mask)
                case false:
                    ((sourceBitPattern &+ delta) & mask, (sinkBitPattern &- delta) & mask)
            }
            return RedistributionEdit(
                sourceIndex: sourceIndex,
                sinkIndex: sinkIndex,
                sourceEntry: sourceEntry.withBitPattern(newSourceBitPattern),
                sinkEntry: sinkEntry.withBitPattern(newSinkBitPattern)
            )
        }

        // Narrow-sink fallback: UInt64 bit-pattern arithmetic with explicit bounds enforcement.
        let patterns = Self.checkedTransferPatterns(
            sourceBitPattern: sourceBitPattern,
            sinkBitPattern: sinkBitPattern,
            sourceMovesDownward: sourceBitPattern > targetBitPattern,
            delta: delta
        )
        guard let (newSourceBitPattern, newSinkBitPattern) = patterns else {
            return nil
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

        return RedistributionEdit(
            sourceIndex: sourceIndex,
            sinkIndex: sinkIndex,
            sourceEntry: sourceEntry.withBitPattern(newSourceBitPattern),
            sinkEntry: sinkEntry.withBitPattern(newSinkBitPattern)
        )
    }

    /// Rejects unsigned overflow and underflow before type-width or explicit-domain validation.
    ///
    /// Both the narrow integer path and mixed rational path use additive, order-preserving encodings. For rational numerators, checked pattern bounds are exactly the `Int64` bounds, allowing deltas larger than `Int64.max` when both results still fit.
    static func checkedTransferPatterns(
        sourceBitPattern: UInt64,
        sinkBitPattern: UInt64,
        sourceMovesDownward: Bool,
        delta: UInt64
    ) -> (source: UInt64, sink: UInt64)? {
        switch sourceMovesDownward {
            case true:
                guard sourceBitPattern >= delta else {
                    return nil
                }
                let (sinkSum, sinkOverflow) = sinkBitPattern.addingReportingOverflow(delta)
                guard sinkOverflow == false else {
                    return nil
                }
                return (sourceBitPattern - delta, sinkSum)
            case false:
                guard sinkBitPattern >= delta else {
                    return nil
                }
                let (sourceSum, sourceOverflow) = sourceBitPattern.addingReportingOverflow(delta)
                guard sourceOverflow == false else {
                    return nil
                }
                return (sourceSum, sinkBitPattern - delta)
        }
    }
}
