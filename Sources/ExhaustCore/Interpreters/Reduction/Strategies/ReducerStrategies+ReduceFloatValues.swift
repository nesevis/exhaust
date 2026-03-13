//
//  ReducerStrategies+ReduceFloatValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/3/2026.
//

extension ReducerStrategies {
    /// Hypothesis-style four-stage float shrinking pipeline for double/float value spans.
    ///
    /// Stages (in order per span):
    /// 1. Special-value short-circuit (greatest finite magnitude, infinity, NaN)
    /// 2. Precision truncation (floor/ceil at powers of two)
    /// 3. Integer-domain binary search for integral floats
    /// 4. `as_integer_ratio`-style integer-part minimization
    ///
    /// Integral values are skipped — see ``reduceIntegralValues``.
    ///
    /// - Complexity: O(*n* · *k* · *M*), where *n* is the number of float value spans, *k* is the constant number of candidates per stage, and *M* is the cost of a single property invocation.
    static func reduceFloatValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSpan],
        rejectCache: inout ReducerCache,
        bindIndex: BindSpanIndex? = nil,
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var currentHash = current.zobristHash
        var progress = false
        var latestOutput: Output?

        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard let v = current[seqIdx].value else { continue }

            let choiceTag = v.choice.tag
            guard choiceTag == .double || choiceTag == .float else { continue }

            let validRange = v.validRange
            let isRangeExplicit = v.isRangeExplicit
            let currentBP = v.choice.bitPattern64
            let semanticTargetBP = v.choice.semanticSimplest.bitPattern64
            let isWithinRecordedRange = v.isRangeExplicit && v.choice.fits(in: validRange)
            let targetBP = isWithinRecordedRange
                ? v.choice.reductionTarget(in: validRange)
                : semanticTargetBP

            if currentBP == targetBP { continue }

            // Try target directly
            let targetChoice = ChoiceValue(
                choiceTag.makeConvertible(bitPattern64: targetBP),
                tag: choiceTag,
            )
            let targetEntry = ChoiceSequenceValue.reduced(.init(choice: targetChoice, validRange: validRange, isRangeExplicit: isRangeExplicit))
            let targetHash = ChoiceSequence.zobristHashUpdating(currentHash, at: seqIdx, replacing: current[seqIdx], with: targetEntry)
            var candidate = current
            candidate[seqIdx] = targetEntry
            if targetEntry.shortLexCompare(current[seqIdx]) == .lt, rejectCache.contains(candidate, zobristHash: targetHash) == false {
                if let output = try? ReducerStrategies.materializeCandidate(gen, tree: tree, candidate: candidate, bindIndex: bindIndex, mutatedIndex: seqIdx),
                   property(output) == false
                {
                    current = candidate
                    currentHash = targetHash
                    latestOutput = output
                    progress = true
                    continue
                } else {
                    rejectCache.insert(candidate, zobristHash: targetHash)
                }
            }

            // Stage 1: special-value short-circuit candidates
            if tryFloatSpecialValueShrinks(
                seqIdx: seqIdx,
                choiceTag: choiceTag,
                value: v,
                isWithinRecordedRange: isWithinRecordedRange,
                currentSequence: &current,
                gen: gen,
                tree: tree,
                property: property,
                latestOutput: &latestOutput,
                progress: &progress,
                rejectCache: &rejectCache,
                bindIndex: bindIndex,
            ) {
                currentHash = current.zobristHash
                continue
            }

            // Stage 2: precision truncation candidates
            if tryFloatTruncationShrinks(
                seqIdx: seqIdx,
                choiceTag: choiceTag,
                value: v,
                isWithinRecordedRange: isWithinRecordedRange,
                currentSequence: &current,
                gen: gen,
                tree: tree,
                property: property,
                latestOutput: &latestOutput,
                progress: &progress,
                rejectCache: &rejectCache,
                bindIndex: bindIndex,
            ) {
                currentHash = current.zobristHash
                continue
            }

            // Stage 3: integer-domain binary search for integral floats
            if tryIntegralFloatBinaryReduction(
                seqIdx: seqIdx,
                choiceTag: choiceTag,
                value: v,
                isWithinRecordedRange: isWithinRecordedRange,
                currentSequence: &current,
                gen: gen,
                tree: tree,
                property: property,
                latestOutput: &latestOutput,
                progress: &progress,
                rejectCache: &rejectCache,
                bindIndex: bindIndex,
            ) {
                currentHash = current.zobristHash
                continue
            }

            // Stage 4: as_integer_ratio-style integer-part minimization
            if tryFloatAsIntegerRatioReduction(
                seqIdx: seqIdx,
                choiceTag: choiceTag,
                value: v,
                isWithinRecordedRange: isWithinRecordedRange,
                currentSequence: &current,
                gen: gen,
                tree: tree,
                property: property,
                latestOutput: &latestOutput,
                progress: &progress,
                rejectCache: &rejectCache,
                bindIndex: bindIndex,
            ) {
                currentHash = current.zobristHash
                continue
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    // MARK: - Float helpers

    /// Tries Hypothesis-style "short-circuit" float candidates: greatest finite magnitude, infinity, and NaN.
    /// Returns `true` if a candidate was accepted.
    private static func tryFloatSpecialValueShrinks<Output>( // swiftlint:disable:this function_parameter_count
        seqIdx: Int,
        choiceTag: TypeTag,
        value: ChoiceSequenceValue.Value,
        isWithinRecordedRange: Bool,
        currentSequence: inout ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        latestOutput: inout Output?,
        progress: inout Bool,
        rejectCache: inout ReducerCache,
        bindIndex: BindSpanIndex? = nil,
    ) -> Bool {
        guard case .floating = value.choice else {
            return false
        }

        for special in FloatShrink.specialValues(for: choiceTag) {
            guard let candidateChoice = floatingChoice(from: special, tag: choiceTag, allowNonFinite: true) else {
                continue
            }
            if tryAcceptFloatCandidate(
                seqIdx: seqIdx,
                currentValue: value,
                candidateChoice: candidateChoice,
                isWithinRecordedRange: isWithinRecordedRange,
                currentSequence: &currentSequence,
                gen: gen,
                tree: tree,
                property: property,
                latestOutput: &latestOutput,
                progress: &progress,
                rejectCache: &rejectCache,
                bindIndex: bindIndex,
            ) {
                return true
            }
        }

        return false
    }

    /// Tries Hypothesis-style float truncation shrinks: for p in 0...9, consider floor(value * 2^p) / 2^p and ceil(value * 2^p) / 2^p.
    /// Returns `true` if a candidate was accepted.
    private static func tryFloatTruncationShrinks<Output>( // swiftlint:disable:this function_parameter_count
        seqIdx: Int,
        choiceTag: TypeTag,
        value: ChoiceSequenceValue.Value,
        isWithinRecordedRange: Bool,
        currentSequence: inout ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        latestOutput: inout Output?,
        progress: inout Bool,
        rejectCache: inout ReducerCache,
        bindIndex: BindSpanIndex? = nil,
    ) -> Bool {
        guard case let .floating(currentFloatingValue, _, _) = value.choice,
              currentFloatingValue.isFinite
        else {
            return false
        }

        var seenBitPatterns = Set<UInt64>()

        for p in 0 ..< 10 {
            let scale = Double(1 << p)
            let scaled = currentFloatingValue * scale
            guard scaled.isFinite else { continue }

            for truncated in [scaled.rounded(.down), scaled.rounded(.up)] {
                let candidateFloatingValue = truncated / scale
                guard candidateFloatingValue.isFinite,
                      let candidateChoice = floatingChoice(from: candidateFloatingValue, tag: choiceTag)
                else {
                    continue
                }

                let candidateBitPattern = candidateChoice.bitPattern64
                guard candidateBitPattern != value.choice.bitPattern64,
                      seenBitPatterns.insert(candidateBitPattern).inserted
                else {
                    continue
                }

                if tryAcceptFloatCandidate(
                    seqIdx: seqIdx,
                    currentValue: value,
                    candidateChoice: candidateChoice,
                    isWithinRecordedRange: isWithinRecordedRange,
                    currentSequence: &currentSequence,
                    gen: gen,
                    tree: tree,
                    property: property,
                    latestOutput: &latestOutput,
                    progress: &progress,
                    rejectCache: &rejectCache,
                    bindIndex: bindIndex,
                    ) {
                    return true
                }
            }
        }

        return false
    }

    private static func floatingChoice(from value: Double, tag: TypeTag, allowNonFinite: Bool = false) -> ChoiceValue? {
        switch tag {
        case .double:
            guard allowNonFinite || value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard allowNonFinite || narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        default:
            return nil
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func tryAcceptFloatCandidate<Output>(
        seqIdx: Int,
        currentValue: ChoiceSequenceValue.Value,
        candidateChoice: ChoiceValue,
        isWithinRecordedRange: Bool,
        currentSequence: inout ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        latestOutput: inout Output?,
        progress: inout Bool,
        rejectCache: inout ReducerCache,
        bindIndex: BindSpanIndex? = nil,
    ) -> Bool {
        guard candidateChoice.bitPattern64 != currentValue.choice.bitPattern64 else {
            return false
        }
        if isWithinRecordedRange, candidateChoice.fits(in: currentValue.validRange) == false {
            return false
        }

        let candidateEntry = ChoiceSequenceValue.reduced(.init(
            choice: candidateChoice,
            validRange: currentValue.validRange,
            isRangeExplicit: currentValue.isRangeExplicit,
        ))
        guard candidateEntry.shortLexCompare(currentSequence[seqIdx]) == .lt else {
            return false
        }

        var candidate = currentSequence
        candidate[seqIdx] = candidateEntry
        guard rejectCache.contains(candidate) == false else {
            return false
        }

        if let output = try? ReducerStrategies.materializeCandidate(gen, tree: tree, candidate: candidate, bindIndex: bindIndex, mutatedIndex: seqIdx),
           property(output) == false
        {
            currentSequence = candidate
            latestOutput = output
            progress = true
            return true
        }

        rejectCache.insert(candidate)
        return false
    }

    // swiftlint:disable:next function_parameter_count
    private static func tryIntegralFloatBinaryReduction<Output>(
        seqIdx: Int,
        choiceTag: TypeTag,
        value: ChoiceSequenceValue.Value,
        isWithinRecordedRange: Bool,
        currentSequence: inout ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        latestOutput: inout Output?,
        progress: inout Bool,
        rejectCache: inout ReducerCache,
        bindIndex: BindSpanIndex? = nil,
    ) -> Bool {
        guard case let .floating(currentFloatingValue, _, _) = value.choice,
              currentFloatingValue.isFinite,
              currentFloatingValue == currentFloatingValue.rounded(.towardZero),
              abs(currentFloatingValue) <= Double(Int64.max)
        else {
            return false
        }

        let currentInt = Int64(currentFloatingValue)
        let targetInt: Int64 = 0
        let movesUp = targetInt > currentInt
        let distance = movesUp ? UInt64(targetInt - currentInt) : UInt64(currentInt - targetInt)
        guard distance > 1 else { return false }

        // Quantize integer-domain probes to at least the current ULP so each accepted
        // step is representable in the underlying float format.
        let currentULP = switch choiceTag {
        case .double:
            currentFloatingValue.ulp
        case .float:
            Double(Float(currentFloatingValue).ulp)
        default:
            1.0
        }
        guard currentULP.isFinite else { return false }
        let minMeaningfulDelta = UInt64(max(1.0, currentULP.rounded(.up)))
        guard minMeaningfulDelta > 0 else { return false }
        let maxQuantum = distance / minMeaningfulDelta
        guard maxQuantum > 0 else { return false }
        let searchUpperBound = maxQuantum + 1

        var probe = currentSequence
        var bestProbeEntry: ChoiceSequenceValue?
        var bestProbeOutput: Output?
        var bestProbeQuantum: UInt64 = 0

        let bestQuantum = AdaptiveProbe.binarySearchWithGuess(
            { (quantum: UInt64) -> Bool in
                if quantum == 0 { return true }
                guard quantum <= maxQuantum else { return false }
                let delta = quantum * minMeaningfulDelta
                guard delta <= UInt64(Int64.max) else { return false }
                let signedDelta = Int64(delta)
                let candidateInt = movesUp
                    ? currentInt + signedDelta
                    : currentInt - signedDelta
                let candidateDouble = Double(candidateInt)
                guard let candidateChoice = floatingChoice(from: candidateDouble, tag: choiceTag) else {
                    return false
                }
                // No-op probes can happen when the chosen delta is smaller than
                // the representable step after type conversion.
                if candidateChoice.bitPattern64 == value.choice.bitPattern64 {
                    return true
                }
                let candidateEntry = ChoiceSequenceValue.reduced(.init(
                    choice: candidateChoice,
                    validRange: value.validRange,
                    isRangeExplicit: value.isRangeExplicit,
                ))
                if isWithinRecordedRange, candidateChoice.fits(in: value.validRange) == false {
                    return false
                }
                guard candidateEntry.shortLexCompare(currentSequence[seqIdx]) == .lt else { return false }
                probe[seqIdx] = candidateEntry
                guard rejectCache.contains(probe) == false else { return false }
                guard let output = try? ReducerStrategies.materializeCandidate(gen, tree: tree, candidate: probe, bindIndex: bindIndex, mutatedIndex: seqIdx) else {
                    rejectCache.insert(probe)
                    return false
                }

                let fails = property(output) == false
                if fails {
                    if quantum >= bestProbeQuantum {
                        bestProbeQuantum = quantum
                        bestProbeEntry = candidateEntry
                        bestProbeOutput = output
                    }
                } else {
                    rejectCache.insert(probe)
                }
                return fails
            },
            low: UInt64(0),
            high: searchUpperBound,
        )

        guard bestQuantum > 0,
              bestProbeQuantum == bestQuantum,
              let bestProbeEntry,
              let bestProbeOutput
        else {
            return false
        }

        currentSequence[seqIdx] = bestProbeEntry
        latestOutput = bestProbeOutput
        progress = true
        return true
    }

    // swiftlint:disable:next function_parameter_count
    private static func tryFloatAsIntegerRatioReduction<Output>(
        seqIdx: Int,
        choiceTag: TypeTag,
        value: ChoiceSequenceValue.Value,
        isWithinRecordedRange: Bool,
        currentSequence: inout ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        latestOutput: inout Output?,
        progress: inout Bool,
        rejectCache: inout ReducerCache,
        bindIndex: BindSpanIndex? = nil,
    ) -> Bool {
        guard case let .floating(currentFloatingValue, _, _) = value.choice,
              currentFloatingValue.isFinite,
              abs(currentFloatingValue) <= FloatShrink.maxPreciseInteger(for: choiceTag),
              let ratio = FloatShrink.integerRatio(for: currentFloatingValue, tag: choiceTag)
        else {
            return false
        }

        guard ratio.denominator > 1, ratio.denominator <= UInt64(Int64.max) else {
            return false
        }

        let denominator = Int64(ratio.denominator)
        let (integerPart, remainder) = floorDivMod(ratio.numerator, denominator)
        let targetInt: Int64 = 0
        let movesUp = targetInt > integerPart
        let distance = movesUp
            ? UInt64(targetInt - integerPart)
            : UInt64(integerPart - targetInt)
        guard distance > 0 else { return false }
        let searchUpperBound = distance + 1

        var probe = currentSequence
        var bestProbeEntry: ChoiceSequenceValue?
        var bestProbeOutput: Output?
        var bestProbeDelta: UInt64 = 0

        let bestDelta = AdaptiveProbe.binarySearchWithGuess(
            { (delta: UInt64) -> Bool in
                if delta == 0 { return true }
                guard delta <= distance, delta <= UInt64(Int64.max) else {
                    return false
                }
                let signedDelta = Int64(delta)
                let candidateInteger = movesUp
                    ? integerPart + signedDelta
                    : integerPart - signedDelta

                let (scaledNumerator, multiplyOverflow) = candidateInteger.multipliedReportingOverflow(by: denominator)
                guard multiplyOverflow == false else { return false }
                let (candidateNumerator, addOverflow) = scaledNumerator.addingReportingOverflow(remainder)
                guard addOverflow == false else { return false }

                let candidateFloatingValue = Double(candidateNumerator) / Double(denominator)
                guard let candidateChoice = floatingChoice(from: candidateFloatingValue, tag: choiceTag) else {
                    return false
                }

                if candidateChoice.bitPattern64 == value.choice.bitPattern64 {
                    return true
                }
                let candidateEntry = ChoiceSequenceValue.reduced(.init(
                    choice: candidateChoice,
                    validRange: value.validRange,
                    isRangeExplicit: value.isRangeExplicit,
                ))
                if isWithinRecordedRange, candidateChoice.fits(in: value.validRange) == false {
                    return false
                }
                guard candidateEntry.shortLexCompare(currentSequence[seqIdx]) == .lt else {
                    return false
                }
                probe[seqIdx] = candidateEntry
                guard rejectCache.contains(probe) == false else {
                    return false
                }
                guard let output = try? ReducerStrategies.materializeCandidate(gen, tree: tree, candidate: probe, bindIndex: bindIndex, mutatedIndex: seqIdx) else {
                    rejectCache.insert(probe)
                    return false
                }

                let fails = property(output) == false
                if fails {
                    if delta >= bestProbeDelta {
                        bestProbeDelta = delta
                        bestProbeEntry = candidateEntry
                        bestProbeOutput = output
                    }
                } else {
                    rejectCache.insert(probe)
                }
                return fails
            },
            low: UInt64(0),
            high: searchUpperBound,
        )

        guard bestDelta > 0,
              bestProbeDelta == bestDelta,
              let bestProbeEntry,
              let bestProbeOutput
        else {
            return false
        }

        currentSequence[seqIdx] = bestProbeEntry
        latestOutput = bestProbeOutput
        progress = true
        return true
    }

    /// Floor division with non-negative remainder for positive denominators.
    private static func floorDivMod(_ numerator: Int64, _ denominator: Int64) -> (quotient: Int64, remainder: Int64) {
        precondition(denominator > 0)
        var quotient = numerator / denominator
        var remainder = numerator % denominator
        if remainder < 0 {
            quotient -= 1
            remainder += denominator
        }
        return (quotient, remainder)
    }
}
