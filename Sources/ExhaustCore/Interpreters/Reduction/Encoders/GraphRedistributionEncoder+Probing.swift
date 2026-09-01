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
            let maxDelta: UInt64 = sourceMetadata.value.bitPattern64 > sourceTarget
                ? sourceMetadata.value.bitPattern64 - sourceTarget
                : sourceTarget - sourceMetadata.value.bitPattern64
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

        // Sort by value-projection shortlex of each pair's full-delta candidate. Pairs whose full-delta probe produces the smallest value shortlex fire first: they make the most progress per probe, which matters when the futility budget is tight. Pre-building candidates is cheap (at most `maxPairsPerScope` sequence copies, each changing exactly two entries). Pairs whose full-delta candidate cannot be built sort last; among those, largest maxDelta sorts first as a fallback.
        //
        // A Nash-gap dependency tier above this sort was tried and reverted: ``ConvergenceSignal/zeroingDependency`` marks leaves that individually reached target despite batch-zero failure, and target-converged leaves are excluded from sources by the `maxDelta > 0` guard, so the tier was uniform. Coupling-aware ordering needs a verdict that marks non-target floors first.
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
                    lhsCandidate.shortLexPrecedes(rhsCandidate)
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case (.none, .none):
                    pairs[lhs].maxDelta > pairs[rhs].maxDelta
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
    /// For same-tag integer pairs the source moves toward its own reduction target, so its new bit pattern stays inside `[min(currentBP, targetBP), max(currentBP, targetBP)]` and never leaves the source's valid range regardless of whether that range is narrow or full-width. Mixed pairs move in their context's direction.
    func buildRedistributionCandidate(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        sinkTag _: TypeTag,
        delta: UInt64,
        mixedContext: MixedRedistributionContext?
    ) -> ChoiceSequence? {
        if let context = mixedContext {
            return valueState.sequence.transferringMagnitude(
                sourceIndex: sourceIndex,
                sinkIndex: sinkIndex,
                sourceTag: sourceTag,
                delta: delta,
                sourceMovesUpward: context.sourceMovesUpward,
                mixedContext: context
            )
        }

        guard let sourceValue = valueState.sequence[sourceIndex].value else { return nil }
        let sourceBitPattern = sourceValue.choice.bitPattern64
        let targetBitPattern = sourceValue.choice.reductionTarget(in: sourceValue.validRange)
        return valueState.sequence.transferringMagnitude(
            sourceIndex: sourceIndex,
            sinkIndex: sinkIndex,
            sourceTag: sourceTag,
            delta: delta,
            sourceMovesUpward: sourceBitPattern <= targetBitPattern,
            mixedContext: nil
        )
    }
}
