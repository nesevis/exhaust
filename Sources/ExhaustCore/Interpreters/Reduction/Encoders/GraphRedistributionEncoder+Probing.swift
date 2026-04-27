//
//  GraphRedistributionEncoder+Probing.swift
//  Exhaust
//

// MARK: - Redistribution

extension GraphRedistributionEncoder {
    mutating func startRedistribution(
        scope: RedistributionScope,
        graph: ChoiceGraph
    ) {
        var pairs: [(sourceIndex: Int, sinkIndex: Int, sourceTag: TypeTag, sinkTag: TypeTag, maxDelta: UInt64, mixedContext: MixedRedistributionContext?)] = []

        for pair in scope.pairs {
            guard let sourceRange = graph.nodes[pair.source.nodeID].positionRange,
                  let sinkRange = graph.nodes[pair.sink.nodeID].positionRange
            else {
                continue
            }
            guard case let .chooseBits(sourceMetadata) = graph.nodes[pair.source.nodeID].kind,
                  case let .chooseBits(sinkMetadata) = graph.nodes[pair.sink.nodeID].kind
            else {
                continue
            }

            guard sourceMetadata.typeTag.isCharacter == false,
                  sinkMetadata.typeTag.isCharacter == false
            else { continue }

            let needsMixedMath = sourceMetadata.typeTag != sinkMetadata.typeTag
                || sourceMetadata.typeTag.isFloatingPoint
                || sinkMetadata.typeTag.isFloatingPoint

            if needsMixedMath {
                // Build a rational-arithmetic context. Handles same-tag float pairs and any cross-type combination.
                guard let context = Self.makeMixedRedistributionContext(
                    sourceChoice: sourceMetadata.value,
                    sinkChoice: sinkMetadata.value,
                    sourceValidRange: sourceMetadata.validRange,
                    sourceIsRangeExplicit: sourceMetadata.isRangeExplicit
                ) else {
                    continue
                }
                pairs.append((
                    sourceIndex: sourceRange.lowerBound,
                    sinkIndex: sinkRange.lowerBound,
                    sourceTag: sourceMetadata.typeTag,
                    sinkTag: sinkMetadata.typeTag,
                    maxDelta: context.distanceInSteps,
                    mixedContext: context
                ))
                continue
            }

            // Same-tag integer pair: bit-pattern arithmetic.
            let sourceTarget = sourceMetadata.value.reductionTarget(in: sourceMetadata.validRange)
            let maxDelta: UInt64 = if sourceMetadata.value.bitPattern64 > sourceTarget {
                sourceMetadata.value.bitPattern64 - sourceTarget
            } else {
                sourceTarget - sourceMetadata.value.bitPattern64
            }
            guard maxDelta > 0 else { continue }

            pairs.append((
                sourceIndex: sourceRange.lowerBound,
                sinkIndex: sinkRange.lowerBound,
                sourceTag: sourceMetadata.typeTag,
                sinkTag: sinkMetadata.typeTag,
                maxDelta: maxDelta,
                mixedContext: nil
            ))
        }

        guard pairs.isEmpty == false else { return }

        // Sort by value-projection shortlex of each pair's full-delta candidate. Pairs whose full-delta probe produces the smallest value shortlex fire first — they make the most progress per probe, which matters when the futility budget is tight. Pre-building candidates is cheap (at most `maxPairsPerScope` sequence copies, each changing exactly two entries). Pairs whose full-delta candidate cannot be built sort last; among those, largest maxDelta sorts first as a fallback.
        let fullDeltaCandidates: [ChoiceSequence?] = pairs.map { pair in
            buildRedistributionCandidate(
                sourceIndex: pair.sourceIndex,
                sinkIndex: pair.sinkIndex,
                sourceTag: pair.sourceTag,
                sinkTag: pair.sinkTag,
                delta: pair.maxDelta,
                mixedContext: pair.mixedContext
            )
        }
        let sortedIndices = pairs.indices.sorted { lhs, rhs in
            switch (fullDeltaCandidates[lhs], fullDeltaCandidates[rhs]) {
            case let (.some(lhsCandidate), .some(rhsCandidate)):
                return lhsCandidate.shortLexPrecedes(rhsCandidate)
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return pairs[lhs].maxDelta > pairs[rhs].maxDelta
            }
        }
        pairs = sortedIndices.map { pairs[$0] }

        // Cap the working set to limited subset of pairs. After sorting, the prefix is the highest-yield slice; the tail is the long stretch of low-distance pairs whose acceptance rate is near zero on workloads with many type-compatible leaves.
        if pairs.count > Self.maxPairsPerScope {
            pairs.removeLast(pairs.count - Self.maxPairsPerScope)
        }

        mode = .active(RedistributionState(
            pairs: pairs,
            pairIndex: 0,
            stepper: nil,
            didEmitCandidate: false,
            lastEmittedCandidate: nil,
            triedFullDelta: false,
            acceptedPairIndices: [],
            passCount: 0,
            activePairIndices: nil
        ))
    }

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
                // Recompute maxDelta from the CURRENT sequence — prior pair acceptances may have changed the source's value.
                let (currentMax, freshContext) = currentMaxDelta(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    sourceTag: pair.sourceTag,
                    sinkTag: pair.sinkTag,
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
                        sinkTag: pair.sinkTag,
                        delta: currentMax,
                        mixedContext: freshContext
                    ) {
                        state.didEmitCandidate = true
                        state.lastEmittedCandidate = candidate
                        return candidate
                    }
                    // Full delta rejected — fall through to binary search.
                }

                // Fall back to binary search on delta magnitude.
                state.stepper = MaxBinarySearchStepper(
                    lo: 0,
                    hi: currentMax
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
                    sinkTag: pair.sinkTag,
                    delta: firstDelta,
                    mixedContext: freshContext
                ) {
                    state.didEmitCandidate = true
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
                // First stepper probe not viable — advance stepper.
            }

            let feedback = state.didEmitCandidate ? lastAccepted : false
            state.didEmitCandidate = false

            // If full-delta was just accepted, the source is zeroed.
            // Skip binary search, move to next pair immediately.
            if feedback, state.stepper == nil {
                state.pairIndex += 1
                state.triedFullDelta = false
                continue
            }

            if let nextDelta = state.stepper?.advance(lastAccepted: feedback) {
                // Re-fetch fresh context for each probe in case prior acceptances changed values.
                let (_, freshContext) = currentMaxDelta(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    sourceTag: pair.sourceTag,
                    sinkTag: pair.sinkTag,
                    usesMixed: pair.mixedContext != nil
                )
                if let candidate = buildRedistributionCandidate(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    sourceTag: pair.sourceTag,
                    sinkTag: pair.sinkTag,
                    delta: nextDelta,
                    mixedContext: freshContext
                ) {
                    state.didEmitCandidate = true
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
                continue
            }

            // Stepper converged for this pair — move to next.
            state.stepper = nil
            state.pairIndex += 1
            state.triedFullDelta = false
        }

        // All pairs exhausted. If any were accepted this pass and we haven't hit the pass cap, reset for another pass — but only re-evaluate the pairs that made progress. This avoids wasting O(pairs × log(maxDelta)) probes on pairs that can't redistribute.
        state.passCount += 1
        if state.acceptedPairIndices.isEmpty == false, state.passCount < Self.maxPasses {
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
        sourceTag _: TypeTag,
        sinkTag _: TypeTag,
        usesMixed: Bool
    ) -> (maxDelta: UInt64, mixedContext: MixedRedistributionContext?) {
        guard let sourceValue = valueState.sequence[sourceIndex].value else {
            return (0, nil)
        }

        if usesMixed {
            guard let sinkValue = valueState.sequence[sinkIndex].value else { return (0, nil) }
            guard let context = Self.makeMixedRedistributionContext(
                sourceChoice: sourceValue.choice,
                sinkChoice: sinkValue.choice,
                sourceValidRange: sourceValue.validRange,
                sourceIsRangeExplicit: sourceValue.isRangeExplicit
            ) else { return (0, nil) }
            return (context.distanceInSteps, context)
        }

        // Same-tag integer: bit-pattern distance.
        let sourceBitPattern = sourceValue.choice.bitPattern64
        let targetBitPattern = sourceValue.choice.reductionTarget(in: sourceValue.validRange)
        let distance = sourceBitPattern > targetBitPattern ? sourceBitPattern - targetBitPattern : targetBitPattern - sourceBitPattern
        return (distance, nil)
    }

    /// Builds a redistribution candidate by transferring `delta` units from source to sink.
    ///
    /// For pairs with a ``MixedRedistributionContext`` (cross-type or floating-point), uses rational arithmetic with a common denominator. For same-tag integer pairs, operates in UInt64 bit-pattern space — modular wraparound when the sink's declared domain equals its natural type width, validation-with-rejection when the sink has an explicit narrow range. See `graph-exchange-semantic-cast-removal.md` for the rationale behind the same-tag arithmetic choices.
    func buildRedistributionCandidate(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        sinkTag _: TypeTag,
        delta: UInt64,
        mixedContext: MixedRedistributionContext?
    ) -> ChoiceSequence? {
        guard delta > 0 else { return nil }

        let sourceEntry = valueState.sequence[sourceIndex]
        let sinkEntry = valueState.sequence[sinkIndex]
        guard let sourceValue = sourceEntry.value else { return nil }
        guard let sinkValue = sinkEntry.value else { return nil }

        // Mixed/rational path for cross-type or float pairs.
        if let context = mixedContext {
            guard let (newSourceChoice, newSinkChoice) = Self.mixedRedistributedPairChoices(
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

            var candidate = valueState.sequence
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
        // The gate is on the sink, not the source. The source moves toward its own reduction target — a contraction inside `[min(currentBP, targetBP), max(currentBP, targetBP)]` — so its new bp never leaves the source's own valid range regardless of whether that range is narrow or full-width. The sink is the side that can escape its valid range as it absorbs the opposing delta, so the sink is the side that determines which sub-path we take.
        //
        // When the sink's declared domain equals the natural type width, we use bit-pattern modular arithmetic with a width-aware mask. This matches the wrapping arithmetic (`&+`/`&-`) the property under test likely uses for the same type and lets redistribution reach boundary counterexamples like `(Int16.min, -1)` that semantic-space arithmetic would reject as overflow. See
        // `bound5-redistribution-wraparound-diagnosis.md` for the motivating trace.
        //
        // When the sink carries an explicit narrow range, we still operate in UInt64 bit-pattern space (signed types are biased via the
        // `signBitMask` XOR in their `BitPatternConvertible` conformance, so additive arithmetic in biased space matches semantic arithmetic), but we use overflow-checked operations and reject — rather than wrap — any candidate that lands outside the sink's `validRange` or the type's natural bounds. See
        // `graph-exchange-semantic-cast-removal.md` for the rationale and for the discussion of the latent bugs in the previous semantic-Int64 implementation that this rewrite addresses.
        let sourceBitPattern = sourceValue.choice.bitPattern64
        let sinkBitPattern = sinkValue.choice.bitPattern64
        let targetBitPattern = sourceValue.choice.reductionTarget(in: sourceValue.validRange)

        if sinkValue.allowsModularArithmetic {
            let mask = sinkValue.choice.tag.bitPatternRange.upperBound
            let newSourceBitPattern: UInt64
            let newSinkBitPattern: UInt64
            if sourceBitPattern > targetBitPattern {
                newSourceBitPattern = (sourceBitPattern &- delta) & mask
                newSinkBitPattern = (sinkBitPattern &+ delta) & mask
            } else {
                newSourceBitPattern = (sourceBitPattern &+ delta) & mask
                newSinkBitPattern = (sinkBitPattern &- delta) & mask
            }

            var candidate = valueState.sequence
            candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBitPattern)
            candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBitPattern)
            return candidate
        }

        // Narrow-sink fallback: UInt64 bit-pattern arithmetic with explicit bounds enforcement.
        let newSourceBitPattern: UInt64
        let newSinkBitPattern: UInt64
        if sourceBitPattern > targetBitPattern {
            // Source moves down (toward target), sink moves up.
            // The encoder bounds delta to `currentMaxDelta`'s `distance = sourceBitPattern - targetBitPattern`, and `targetBitPattern >= 0`, so this subtraction cannot underflow. Defensive guard against stale state.
            guard sourceBitPattern >= delta else { return nil }
            newSourceBitPattern = sourceBitPattern - delta
            let (sinkSum, sinkOverflow) = sinkBitPattern.addingReportingOverflow(delta)
            guard sinkOverflow == false else { return nil }
            newSinkBitPattern = sinkSum
        } else {
            // Source moves up (toward target), sink moves down.
            let (sourceSum, sourceOverflow) = sourceBitPattern.addingReportingOverflow(delta)
            guard sourceOverflow == false else { return nil }
            newSourceBitPattern = sourceSum
            guard sinkBitPattern >= delta else { return nil }
            newSinkBitPattern = sinkBitPattern - delta
        }

        // Enforce natural type bounds. Replaces the per-tag range checks that the deleted `bitPattern(fromSemantic:tag:)` helper used to do — `tag.bitPatternRange` is the same set, so this is a structural simplification, not a behavior change.
        guard sourceTag.bitPatternRange.contains(newSourceBitPattern),
              sinkValue.choice.tag.bitPatternRange.contains(newSinkBitPattern)
        else {
            return nil
        }

        // Enforce explicit `validRange`. The mixed/rational path already does this for cross-type and float pairs; the previous semantic-Int64 narrow-sink path was missing this check, which let candidates escape the user's declared domain.
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

        var candidate = valueState.sequence
        candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBitPattern)
        candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBitPattern)
        return candidate
    }
}
