//
//  ReducerStrategies+ReduceValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Binary search each individual value toward its reduction target. Corresponds to Hypothesis's `minimize_individual_blocks` (MacIver & Donaldson, ECOOP 2020, §3.1) with extensions for signed cross-zero probing, stale-range escape hatches, and Hypothesis-style float shrinking paths.
    ///
    /// If recorded ranges appear to block progress, the pass may probe one step beyond the recorded boundary so subsequent loops can continue shrinking with refreshed context.
    ///
    /// - Complexity: O(*n* · log *d* · *M*), where *n* is the number of value spans, *d* is the maximum bit-pattern distance between a value and its reduction target, and *M* is the cost of a single property invocation. The binary search with guess for each value makes O(log *d*) property invocations; the constant-size boundary probe (5 offsets) is dominated.
    static func reduceValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSpan],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var currentHash = current.zobristHash
        var progress = false
        var latestOutput: Output?

        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard let v = current[seqIdx].value else { continue }

            let validRange = v.validRange
            let isRangeExplicit = v.isRangeExplicit
            let choiceTag = v.choice.tag
            let currentBP = v.choice.bitPattern64
            let semanticTargetBP = v.choice.semanticSimplest.bitPattern64
            let isWithinRecordedRange = v.isRangeExplicit && v.choice.fits(in: validRange)
            let targetBP = isWithinRecordedRange
                ? v.choice.reductionTarget(in: validRange)
                : semanticTargetBP
            let currentEntry = current[seqIdx]

            if currentBP == targetBP {
                // Already at recorded-range target. If semantic target lies outside that range,
                // probe one step past the recorded boundary to unlock further shrinking.
                if isWithinRecordedRange, semanticTargetBP != targetBP {
                    if tryUnlockBoundary(
                        .init(
                            seqIdx: seqIdx,
                            choiceTag: choiceTag,
                            currentEntry: currentEntry,
                            currentBP: currentBP,
                            targetBP: targetBP,
                            semanticTargetBP: semanticTargetBP,
                            validRange: validRange,
                            isRangeExplicit: isRangeExplicit,
                        ),
                        gen: gen,
                        tree: tree,
                        property: property,
                        currentSequence: &current,
                        latestOutput: &latestOutput,
                        progress: &progress,
                        rejectCache: &rejectCache,
                    ) {
                        currentHash = current.zobristHash
                    }
                }
                continue
            }

            let searchUpward = targetBP > currentBP
            let distance = searchUpward
                ? targetBP - currentBP
                : currentBP - targetBP
            let fastMaxDelta: UInt64? = {
                guard isWithinRecordedRange,
                      let validRange,
                      validRange.contains(currentBP)
                else {
                    return nil
                }
                return searchUpward
                    ? (validRange.upperBound - currentBP)
                    : (currentBP - validRange.lowerBound)
            }()

            // Try target directly
            let targetChoice = ChoiceValue(
                choiceTag.makeConvertible(bitPattern64: targetBP),
                tag: choiceTag,
            )
            let targetEntry = ChoiceSequenceValue.reduced(.init(choice: targetChoice, validRange: validRange, isRangeExplicit: isRangeExplicit))
            let targetHash = ChoiceSequence.zobristHashUpdating(currentHash, at: seqIdx, replacing: currentEntry, with: targetEntry)
            var candidate = current
            candidate[seqIdx] = targetEntry
            if targetEntry.shortLexCompare(current[seqIdx]) == .lt, rejectCache.contains(candidate, zobristHash: targetHash) == false {
                if let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
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

            // Float-specific fast paths inspired by Hypothesis:
            // 0) special-value short-circuit candidates
            // 1) precision truncation candidates
            // 2) integer-domain binary search for integral floats
            // 3) as_integer_ratio-style integer-part minimization
            // Then stop for this span instead of raw bit-pattern binary search,
            // which can make millions of tiny ULP moves.
            if choiceTag == .double || choiceTag == .float {
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
                ) {
                    currentHash = current.zobristHash
                    continue
                }

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
                ) {
                    currentHash = current.zobristHash
                    continue
                }

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
                ) {
                    currentHash = current.zobristHash
                    continue
                }

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
                ) {
                    currentHash = current.zobristHash
                    continue
                }

                continue
            }

            // Binary search: predicate(delta) means "can we move delta steps toward the target and still fail?"
            // predicate(0) = true (no change), predicate(distance) = false (target was just rejected)
            if distance <= 1 {
                if isWithinRecordedRange, semanticTargetBP != targetBP {
                    if tryUnlockBoundary(
                        .init(
                            seqIdx: seqIdx,
                            choiceTag: choiceTag,
                            currentEntry: currentEntry,
                            currentBP: currentBP,
                            targetBP: targetBP,
                            semanticTargetBP: semanticTargetBP,
                            validRange: validRange,
                            isRangeExplicit: isRangeExplicit,
                        ),
                        gen: gen,
                        tree: tree,
                        property: property,
                        currentSequence: &current,
                        latestOutput: &latestOutput,
                        progress: &progress,
                        rejectCache: &rejectCache,
                    ) {
                        currentHash = current.zobristHash
                    }
                }
                continue
            }
            let originalEntry = current[seqIdx]
            var probe = current
            var bestProbeEntry: ChoiceSequenceValue?
            var bestProbeOutput: Output?
            var bestProbeDelta: UInt64 = 0

            let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                { (delta: UInt64) -> Bool in
                    guard delta > 0 else { return true } // predicate(0) assumed true
                    if let fastMaxDelta, delta > fastMaxDelta {
                        return false
                    }
                    guard searchUpward ? UInt64.max - delta >= currentBP : currentBP >= delta else {
                        return false
                    }
                    let newBP = searchUpward ? currentBP + delta : currentBP - delta
                    let newChoice = ChoiceValue(
                        choiceTag.makeConvertible(bitPattern64: newBP),
                        tag: choiceTag,
                    )
                    if isWithinRecordedRange, newChoice.fits(in: validRange) == false {
                        return false
                    }
                    let probeEntry = ChoiceSequenceValue.reduced(.init(choice: newChoice, validRange: validRange, isRangeExplicit: isRangeExplicit))
                    guard probeEntry.shortLexCompare(originalEntry) == .lt else {
                        return false
                    }
                    probe[seqIdx] = probeEntry
                    let probeHash = ChoiceSequence.zobristHashUpdating(currentHash, at: seqIdx, replacing: originalEntry, with: probeEntry)
                    guard rejectCache.contains(probe, zobristHash: probeHash) == false
                    else {
                        return false
                    }
                    guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
                        rejectCache.insert(probe, zobristHash: probeHash)
                        return false
                    }
                    let fails = property(output) == false
                    if fails {
                        if delta >= bestProbeDelta {
                            bestProbeDelta = delta
                            bestProbeEntry = probeEntry
                            bestProbeOutput = output
                        }
                    } else {
                        rejectCache.insert(probe, zobristHash: probeHash)
                    }
                    return fails
                },
                low: UInt64(0),
                high: distance,
            )

            if bestDelta > 0 {
                if bestProbeDelta == bestDelta, let bestProbeEntry, let bestProbeOutput {
                    current[seqIdx] = bestProbeEntry
                    currentHash = ChoiceSequence.zobristHashUpdating(currentHash, at: seqIdx, replacing: originalEntry, with: bestProbeEntry)
                    latestOutput = bestProbeOutput
                    progress = true
                    continue
                }

                // Fallback: reconstruct accepted candidate if probe bookkeeping missed it.
                let newBP = searchUpward ? currentBP + bestDelta : currentBP - bestDelta
                let newChoice = ChoiceValue(
                    choiceTag.makeConvertible(bitPattern64: newBP),
                    tag: choiceTag,
                )
                let candidateEntry = ChoiceSequenceValue.reduced(.init(choice: newChoice, validRange: validRange, isRangeExplicit: isRangeExplicit))
                var candidate = current
                candidate[seqIdx] = candidateEntry
                if candidateEntry.shortLexCompare(current[seqIdx]) == .lt,
                   let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
                   property(output) == false
                {
                    current = candidate
                    currentHash = current.zobristHash
                    latestOutput = output
                    progress = true
                    continue
                }
            }

            // For signed types, the bit-pattern search can only reach values on the same
            // side of zero. Probe shortlex keys below the current key to try values on
            // the opposite side (closer to zero). e.g. shrinking -2 → 1 for the Distinct challenge.
            var crossZeroImproved = false
            if case .signed = v.choice {
                let currentKey = v.choice.shortlexKey
                if currentKey > 0 {
                    let maxProbes: UInt64 = 16
                    let lowerBound = currentKey > maxProbes ? currentKey - maxProbes : 0
                    var crossZeroProbe = current
                    var probeKey = currentKey
                    while probeKey > lowerBound {
                        probeKey -= 1
                        let probeChoice = ChoiceValue.fromShortlexKey(probeKey, tag: choiceTag)
                        if isWithinRecordedRange, probeChoice.fits(in: validRange) == false { continue }
                        let probeEntry = ChoiceSequenceValue.reduced(.init(choice: probeChoice, validRange: validRange, isRangeExplicit: isRangeExplicit))
                        guard probeEntry.shortLexCompare(current[seqIdx]) == .lt else { continue }
                        crossZeroProbe[seqIdx] = probeEntry
                        guard rejectCache.contains(crossZeroProbe) == false else { continue }
                        if let output = try? Interpreters.materialize(gen, with: tree, using: crossZeroProbe),
                           property(output) == false
                        {
                            current = crossZeroProbe
                            currentHash = current.zobristHash
                            latestOutput = output
                            progress = true
                            crossZeroImproved = true
                            break
                        } else {
                            rejectCache.insert(crossZeroProbe)
                        }
                    }
                }
            }
            if crossZeroImproved { continue }

            if bestDelta == 0 {
                // No reduction was possible here. Let's try
                // **Local boundary search**: Are there better shrinks just beyond the horizon?
                let offsets = [bestDelta + 1, bestDelta + 2, bestDelta + 4, bestDelta + 8, bestDelta + 16]
                var boundary = current
                var boundaryImproved = false
                for offset in offsets {
                    // Let's make sure we don't under or overflow
                    guard searchUpward ? UInt64.max - offset >= currentBP : currentBP >= offset else {
                        continue
                    }
                    let testBP = searchUpward ? currentBP + offset : currentBP - offset
                    let boundaryChoice = ChoiceValue(
                        choiceTag.makeConvertible(bitPattern64: testBP),
                        tag: choiceTag,
                    )
                    if isWithinRecordedRange, boundaryChoice.fits(in: validRange) == false {
                        continue
                    }
                    let boundaryEntry = ChoiceSequenceValue.value(.init(choice: boundaryChoice, validRange: validRange, isRangeExplicit: isRangeExplicit))
                    guard boundaryEntry.shortLexCompare(current[seqIdx]) == .lt else { continue }
                    boundary[seqIdx] = boundaryEntry

                    if rejectCache.contains(boundary) == false {
                        if let output = try? Interpreters.materialize(gen, with: tree, using: boundary),
                           property(output) == false
                        {
                            latestOutput = output
                            current = boundary
                            currentHash = current.zobristHash
                            progress = true
                            boundaryImproved = true
                            break
                        } else {
                            rejectCache.insert(boundary)
                        }
                    }
                }
                if boundaryImproved {
                    continue
                }

                // Escape hatch: if recorded bounds blocked progress, probe one step past
                // that boundary so subsequent loops can continue shrinking from there.
                if isWithinRecordedRange, semanticTargetBP != targetBP {
                    if tryUnlockBoundary(
                        .init(
                            seqIdx: seqIdx,
                            choiceTag: choiceTag,
                            currentEntry: currentEntry,
                            currentBP: currentBP,
                            targetBP: targetBP,
                            semanticTargetBP: semanticTargetBP,
                            validRange: validRange,
                            isRangeExplicit: isRangeExplicit,
                        ),
                        gen: gen,
                        tree: tree,
                        property: property,
                        currentSequence: &current,
                        latestOutput: &latestOutput,
                        progress: &progress,
                        rejectCache: &rejectCache,
                    ) {
                        currentHash = current.zobristHash
                        continue
                    }
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    /// Probes exactly one bit-pattern step past a recorded boundary when `reduceValues` appears range-locked.
    ///
    /// Motivation: `ChoiceSequenceValue.Value.validRange` is recorded from the tree *at the time the value was generated*. During reduction, earlier successful edits can change parent decisions (especially through `bind` and branch pivots), which in turn changes the runtime-valid range for descendants.
    /// The recorded range can then be stale.
    ///
    /// Why this matters: `reduceValues` uses recorded ranges as a fast heuristic to bound binary search. Without an escape hatch, a descendant can become stuck at a stale lower bound forever, even though replay accepts smaller values under the new parent context.
    ///
    /// Concrete examples:
    /// 1. Binary-heap shrink:
    /// A node value drops from `91` to `0`, but grandchildren still carry recorded ranges `91...100`.
    /// Range-gated search cannot move below `91`, so shrinking stalls. Probing `90` succeeds under the updated parent, and subsequent loops continue to `0`, yielding the expected minimal counterexample.
    /// 2. Bind-dependent generator: `Gen.choose(0...100).bind { p in Gen.choose(p...100) }`.
    /// After `p` shrinks, children may still have metadata from the old `p`. Recorded-range search can reject candidates that replay now accepts. One-step unlock re-enters a valid shrinking path.
    ///
    /// Why only one step:
    /// We deliberately avoid globally disabling range guidance. A one-step probe keeps property invocation cost low, preserves the fast path for well-formed metadata, and only activates when pass 5 has no in-range improvement left.
    ///
    /// - Returns: `true` if the unlock candidate was accepted and `currentSequence` was updated.
    private static func tryUnlockBoundary<Output>(
        _ input: UnlockProbeInput,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        currentSequence: inout ChoiceSequence,
        latestOutput: inout Output?,
        progress: inout Bool,
        rejectCache: inout ReducerCache,
    ) -> Bool {
        guard input.semanticTargetBP != input.targetBP else { return false }
        let unlockBP: UInt64? = if input.semanticTargetBP < input.targetBP {
            input.targetBP > 0 ? input.targetBP - 1 : nil
        } else if input.semanticTargetBP > input.targetBP {
            input.targetBP < UInt64.max ? input.targetBP + 1 : nil
        } else {
            nil
        }

        guard let unlockBP,
              unlockBP != input.currentBP
        else {
            return false
        }

        let unlockChoice = ChoiceValue(
            input.choiceTag.makeConvertible(bitPattern64: unlockBP),
            tag: input.choiceTag,
        )
        let unlockEntry = ChoiceSequenceValue.reduced(.init(choice: unlockChoice, validRange: input.validRange, isRangeExplicit: input.isRangeExplicit))
        var unlockCandidate = currentSequence
        unlockCandidate[input.seqIdx] = unlockEntry
        guard unlockEntry.shortLexCompare(input.currentEntry) == .lt,
              rejectCache.contains(unlockCandidate) == false
        else {
            return false
        }

        if let output = try? Interpreters.materialize(gen, with: tree, using: unlockCandidate),
           property(output) == false
        {
            currentSequence = unlockCandidate
            latestOutput = output
            progress = true
            return true
        }

        rejectCache.insert(unlockCandidate)
        return false
    }

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

        if let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
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
                guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
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
                guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
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
