//
//  GraphFloatSearchEncoder.swift
//  Exhaust
//

// MARK: - Graph Float Search Encoder

/// Reduces floating-point leaf values via a four-stage IEEE 754 pipeline.
///
/// Extracts float leaves (`TypeTag.isFloatingPoint`) from the ``ChoiceGraph``'s `chooseBits` nodes and applies, per leaf:
///
/// 0. Special-value short-circuit (greatest finite magnitude, infinity, NaN, reduction target).
/// 1. Precision truncation (floor/ceil at powers of two).
/// 2. Integer-domain binary search for integral floats.
/// 3. `as_integer_ratio`-style integer-part minimization.
///
/// Reuses ``FloatReduction`` for special values and ratio decomposition, and ``FindIntegerStepper`` for stages 2 and 3.
///
/// - SeeAlso: ``ReduceFloatEncoder``, ``GraphValueSearchEncoder``
public struct GraphFloatSearchEncoder: GraphEncoder {
    public let name: EncoderName = .graphFloatSearch

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var targets: [FloatTarget] = []
    private var currentTargetIndex = 0
    private var stage = Stage.specialValues
    private var batchCandidates: [UInt64] = []
    private var batchIndex = 0
    private var stepper = FindIntegerStepper()
    private var needsFirstProbe = true

    // Stage 2/3 context
    private var binarySearchMinDelta: UInt64 = 1
    private var binarySearchMaxQuantum: UInt64 = 0
    private var binarySearchMovesUp = false
    private var binarySearchCurrentInt: Int64 = 0

    // Stage 3 context
    private var ratioDenominator: Int64 = 0
    private var ratioRemainder: Int64 = 0
    private var ratioIntegerPart: Int64 = 0
    private var ratioDistance: UInt64 = 0

    /// Convergence records accumulated during the probe loop.
    public private(set) var convergenceRecords: [Int: ConvergedOrigin] = [:]
    private var currentCycle: Int = 0

    private struct FloatTarget {
        let sequenceIndex: Int
        let tag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        var currentValue: Double
        var currentBitPattern: UInt64
        /// When set, skips batch stages (special values and truncation) on warm start.
        var initialStage: Stage?
    }

    private enum Stage: Int, Comparable {
        case specialValues = 0
        case truncation = 1
        case integralBinarySearch = 2
        case ratioBinarySearch = 3

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree _: ChoiceTree
    ) {
        self.sequence = sequence
        targets = []
        currentTargetIndex = 0
        stage = .specialValues
        batchCandidates = []
        batchIndex = 0
        needsFirstProbe = true
        convergenceRecords = [:]
        currentCycle = 0

        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  let positionRange = node.positionRange
            else { continue }

            guard metadata.typeTag.isFloatingPoint else { continue }
            guard case let .floating(floatingValue, _, _) = metadata.value else { continue }

            let sequenceIndex = positionRange.lowerBound

            // Stage-skip: if the warm start bound matches the current bit pattern,
            // the value is unchanged since last convergence — skip batch stages.
            let skipBatchStages: Stage? = if let convergedOrigin = metadata.convergedOrigin,
                                              convergedOrigin.bound == metadata.value.bitPattern64
            {
                .integralBinarySearch
            } else {
                nil
            }

            targets.append(FloatTarget(
                sequenceIndex: sequenceIndex,
                tag: metadata.typeTag,
                validRange: metadata.validRange,
                isRangeExplicit: metadata.isRangeExplicit,
                currentValue: floatingValue,
                currentBitPattern: metadata.value.bitPattern64,
                initialStage: skipBatchStages
            ))
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        while currentTargetIndex < targets.count {
            if needsFirstProbe {
                needsFirstProbe = false
                // Apply stage-skip from warm start before preparing the first stage.
                if let skip = targets[currentTargetIndex].initialStage, skip > stage {
                    stage = skip
                }
                prepareStage()
            } else if lastAccepted {
                handleAcceptance()
            }

            if let candidate = nextCandidateForCurrentStage(lastAccepted: lastAccepted) {
                return candidate
            }

            // Current stage exhausted — advance to next stage or next target.
            if advanceStageOrTarget() == false {
                return nil
            }
        }
        return nil
    }

    // MARK: - Stage Preparation

    private mutating func prepareStage() {
        guard currentTargetIndex < targets.count else { return }
        let target = targets[currentTargetIndex]
        batchCandidates = []
        batchIndex = 0

        switch stage {
        case .specialValues:
            prepareSpecialValues(target: target)
        case .truncation:
            prepareTruncation(target: target)
        case .integralBinarySearch:
            prepareIntegralBinarySearch(target: target)
        case .ratioBinarySearch:
            prepareRatioBinarySearch(target: target)
        }
    }

    private mutating func prepareSpecialValues(target: FloatTarget) {
        var candidates = [UInt64]()
        // Try reduction target directly.
        guard let value = sequence[target.sequenceIndex].value else { return }
        let isWithinRecordedRange = value.isRangeExplicit && value.choice.fits(in: value.validRange)
        let targetBitPattern = isWithinRecordedRange
            ? value.choice.reductionTarget(in: value.validRange)
            : value.choice.semanticSimplest.bitPattern64
        if targetBitPattern != target.currentBitPattern {
            candidates.append(targetBitPattern)
        }

        for special in FloatReduction.specialValues(for: target.tag) {
            guard let candidateChoice = floatingChoice(
                from: special,
                tag: target.tag,
                allowNonFinite: true
            ) else {
                continue
            }
            let bitPattern = candidateChoice.bitPattern64
            if bitPattern != target.currentBitPattern, candidates.contains(bitPattern) == false {
                candidates.append(bitPattern)
            }
        }

        batchCandidates = candidates
    }

    private mutating func prepareTruncation(target: FloatTarget) {
        guard target.currentValue.isFinite else {
            batchCandidates = []
            return
        }

        var seenBitPatterns = Set<UInt64>()
        var candidates = [UInt64]()

        for power in 0 ..< 10 {
            let scale = Double(1 << power)
            let scaled = target.currentValue * scale
            guard scaled.isFinite else { continue }

            for truncated in [scaled.rounded(.down), scaled.rounded(.up)] {
                let candidateValue = truncated / scale
                guard candidateValue.isFinite,
                      let candidateChoice = floatingChoice(from: candidateValue, tag: target.tag)
                else {
                    continue
                }
                let bitPattern = candidateChoice.bitPattern64
                guard bitPattern != target.currentBitPattern,
                      seenBitPatterns.insert(bitPattern).inserted
                else {
                    continue
                }
                candidates.append(bitPattern)
            }
        }

        batchCandidates = candidates
    }

    private mutating func prepareIntegralBinarySearch(target: FloatTarget) {
        guard target.currentValue.isFinite,
              target.currentValue == target.currentValue.rounded(.towardZero),
              abs(target.currentValue) <= Double(Int64.max)
        else {
            return
        }

        let currentInt = Int64(target.currentValue)
        let targetInt: Int64 = 0
        let movesUp = targetInt > currentInt
        let distance = movesUp ? UInt64(targetInt - currentInt) : UInt64(currentInt - targetInt)
        guard distance > 1 else { return }

        let currentULP: Double = switch target.tag {
        case .double:
            target.currentValue.ulp
        case .float, .float16:
            Double(Float(target.currentValue).ulp)
        default:
            1.0
        }
        guard currentULP.isFinite else { return }
        let minDelta = UInt64(max(1.0, currentULP.rounded(.up)))
        guard minDelta > 0 else { return }
        let maxQuantum = distance / minDelta
        guard maxQuantum > 0 else { return }

        binarySearchMinDelta = minDelta
        binarySearchMaxQuantum = maxQuantum
        binarySearchMovesUp = movesUp
        binarySearchCurrentInt = currentInt
    }

    private mutating func prepareRatioBinarySearch(target: FloatTarget) {
        guard target.currentValue.isFinite,
              abs(target.currentValue) <= FloatReduction.maxPreciseInteger(for: target.tag),
              let ratio = FloatReduction.integerRatio(for: target.currentValue, tag: target.tag)
        else {
            return
        }

        guard ratio.denominator > 1, ratio.denominator <= UInt64(Int64.max) else {
            return
        }

        let denominator = Int64(ratio.denominator)
        let (integerPart, remainder) = floorDivMod(ratio.numerator, denominator)
        let targetInt: Int64 = 0
        let movesUp = targetInt > integerPart
        let distance = movesUp
            ? UInt64(targetInt - integerPart)
            : UInt64(integerPart - targetInt)
        guard distance > 0 else { return }

        ratioDenominator = denominator
        ratioRemainder = remainder
        ratioIntegerPart = integerPart
        ratioDistance = distance
        binarySearchMovesUp = movesUp
    }

    // MARK: - Candidate Generation

    private mutating func nextCandidateForCurrentStage(lastAccepted: Bool) -> ChoiceSequence? {
        switch stage {
        case .specialValues, .truncation:
            nextBatchCandidate()
        case .integralBinarySearch:
            nextIntegralBinarySearchCandidate(lastAccepted: lastAccepted)
        case .ratioBinarySearch:
            nextRatioBinarySearchCandidate(lastAccepted: lastAccepted)
        }
    }

    private mutating func nextBatchCandidate() -> ChoiceSequence? {
        guard currentTargetIndex < targets.count else { return nil }
        let target = targets[currentTargetIndex]
        while batchIndex < batchCandidates.count {
            let bitPattern = batchCandidates[batchIndex]
            batchIndex += 1

            guard let candidateChoice = makeChoice(bitPattern: bitPattern, tag: target.tag) else {
                continue
            }
            if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
                continue
            }

            let candidateEntry = ChoiceSequenceValue.reduced(.init(
                choice: candidateChoice,
                validRange: target.validRange,
                isRangeExplicit: target.isRangeExplicit
            ))
            guard candidateEntry.shortLexCompare(sequence[target.sequenceIndex]) == .lt else {
                continue
            }

            var candidate = sequence
            candidate[target.sequenceIndex] = candidateEntry
            return candidate
        }
        return nil
    }

    private mutating func nextIntegralBinarySearchCandidate(lastAccepted: Bool) -> ChoiceSequence? {
        guard binarySearchMaxQuantum > 0 else { return nil }
        let target = targets[currentTargetIndex]

        let quantum: Int?
        if batchIndex == 0 {
            batchIndex = 1
            quantum = stepper.start()
        } else {
            quantum = stepper.advance(lastAccepted: lastAccepted)
        }

        guard let quantumValue = quantum else {
            if stepper.bestAccepted > 0 {
                applyIntegralBinarySearchBest()
            }
            let currentTarget = targets[currentTargetIndex]
            convergenceRecords[currentTarget.sequenceIndex] = ConvergedOrigin(
                bound: currentTarget.currentBitPattern,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: currentCycle
            )
            return nil
        }

        let quantumU64 = UInt64(quantumValue)
        guard quantumU64 <= binarySearchMaxQuantum else {
            return nextIntegralBinarySearchCandidate(lastAccepted: false)
        }
        let delta = quantumU64 * binarySearchMinDelta
        guard delta <= UInt64(Int64.max) else {
            return nextIntegralBinarySearchCandidate(lastAccepted: false)
        }
        let signedDelta = Int64(delta)
        let candidateInt = binarySearchMovesUp
            ? binarySearchCurrentInt + signedDelta
            : binarySearchCurrentInt - signedDelta
        let candidateDouble = Double(candidateInt)
        guard let candidateChoice = floatingChoice(from: candidateDouble, tag: target.tag) else {
            return nextIntegralBinarySearchCandidate(lastAccepted: false)
        }

        if candidateChoice.bitPattern64 == target.currentBitPattern {
            return nextIntegralBinarySearchCandidate(lastAccepted: true)
        }

        if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
            return nextIntegralBinarySearchCandidate(lastAccepted: false)
        }

        let candidateEntry = ChoiceSequenceValue.reduced(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        guard candidateEntry.shortLexCompare(sequence[target.sequenceIndex]) == .lt else {
            return nextIntegralBinarySearchCandidate(lastAccepted: false)
        }

        var candidate = sequence
        candidate[target.sequenceIndex] = candidateEntry
        return candidate
    }

    private mutating func applyIntegralBinarySearchBest() {
        let target = targets[currentTargetIndex]
        let bestQuantum = UInt64(stepper.bestAccepted)
        let delta = bestQuantum * binarySearchMinDelta
        let signedDelta = Int64(delta)
        let candidateInt = binarySearchMovesUp
            ? binarySearchCurrentInt + signedDelta
            : binarySearchCurrentInt - signedDelta
        let candidateDouble = Double(candidateInt)
        guard let candidateChoice = floatingChoice(
            from: candidateDouble,
            tag: target.tag
        ) else { return }
        let candidateEntry = ChoiceSequenceValue.reduced(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        sequence[target.sequenceIndex] = candidateEntry
        targets[currentTargetIndex].currentValue = candidateDouble
        targets[currentTargetIndex].currentBitPattern = candidateChoice.bitPattern64
    }

    private mutating func nextRatioBinarySearchCandidate(lastAccepted: Bool) -> ChoiceSequence? {
        guard ratioDistance > 0 else { return nil }
        let target = targets[currentTargetIndex]

        let quantum: Int?
        if batchIndex == 0 {
            batchIndex = 1
            quantum = stepper.start()
        } else {
            quantum = stepper.advance(lastAccepted: lastAccepted)
        }

        guard let quantumValue = quantum else {
            if stepper.bestAccepted > 0 {
                applyRatioBinarySearchBest()
            }
            let currentTarget = targets[currentTargetIndex]
            convergenceRecords[currentTarget.sequenceIndex] = ConvergedOrigin(
                bound: currentTarget.currentBitPattern,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: currentCycle
            )
            return nil
        }

        let quantumU64 = UInt64(quantumValue)
        guard quantumU64 <= ratioDistance, quantumU64 <= UInt64(Int64.max) else {
            return nextRatioBinarySearchCandidate(lastAccepted: false)
        }
        let signedDelta = Int64(quantumU64)
        let candidateInteger = binarySearchMovesUp
            ? ratioIntegerPart + signedDelta
            : ratioIntegerPart - signedDelta

        let (scaledNumerator, multiplyOverflow) =
            candidateInteger.multipliedReportingOverflow(by: ratioDenominator)
        guard multiplyOverflow == false else {
            return nextRatioBinarySearchCandidate(lastAccepted: false)
        }
        let (candidateNumerator, addOverflow) =
            scaledNumerator.addingReportingOverflow(ratioRemainder)
        guard addOverflow == false else {
            return nextRatioBinarySearchCandidate(lastAccepted: false)
        }

        let candidateValue = Double(candidateNumerator) / Double(ratioDenominator)
        guard let candidateChoice = floatingChoice(from: candidateValue, tag: target.tag) else {
            return nextRatioBinarySearchCandidate(lastAccepted: false)
        }

        if candidateChoice.bitPattern64 == target.currentBitPattern {
            return nextRatioBinarySearchCandidate(lastAccepted: true)
        }

        if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
            return nextRatioBinarySearchCandidate(lastAccepted: false)
        }

        let candidateEntry = ChoiceSequenceValue.reduced(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        guard candidateEntry.shortLexCompare(sequence[target.sequenceIndex]) == .lt else {
            return nextRatioBinarySearchCandidate(lastAccepted: false)
        }

        var candidate = sequence
        candidate[target.sequenceIndex] = candidateEntry
        return candidate
    }

    private mutating func applyRatioBinarySearchBest() {
        let target = targets[currentTargetIndex]
        let bestQuantum = UInt64(stepper.bestAccepted)
        let signedDelta = Int64(bestQuantum)
        let candidateInteger = binarySearchMovesUp
            ? ratioIntegerPart + signedDelta
            : ratioIntegerPart - signedDelta

        let scaledNumerator = candidateInteger * ratioDenominator
        let candidateNumerator = scaledNumerator + ratioRemainder
        let candidateValue = Double(candidateNumerator) / Double(ratioDenominator)
        guard let candidateChoice = floatingChoice(
            from: candidateValue,
            tag: target.tag
        ) else { return }
        let candidateEntry = ChoiceSequenceValue.reduced(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        sequence[target.sequenceIndex] = candidateEntry
        targets[currentTargetIndex].currentValue = candidateValue
        targets[currentTargetIndex].currentBitPattern = candidateChoice.bitPattern64
    }

    // MARK: - Acceptance

    private mutating func handleAcceptance() {
        let target = targets[currentTargetIndex]
        switch stage {
        case .specialValues, .truncation:
            // Batch stages: acceptance means the last emitted candidate was accepted.
            let bitPattern = batchCandidates[batchIndex - 1]
            if let choice = makeChoice(bitPattern: bitPattern, tag: target.tag) {
                let entry = ChoiceSequenceValue.reduced(.init(
                    choice: choice,
                    validRange: target.validRange,
                    isRangeExplicit: target.isRangeExplicit
                ))
                sequence[target.sequenceIndex] = entry
                if case let .floating(value, _, _) = choice {
                    targets[currentTargetIndex].currentValue = value
                }
                targets[currentTargetIndex].currentBitPattern = bitPattern
            }
            // Advance to next target, restart from stage 0.
            currentTargetIndex += 1
            stage = .specialValues
            needsFirstProbe = true
        case .integralBinarySearch, .ratioBinarySearch:
            // Stepper handles acceptance internally via advance(lastAccepted:).
            break
        }
    }

    // MARK: - Stage/Target Advancement

    private mutating func advanceStageOrTarget() -> Bool {
        let nextStage: Stage? = switch stage {
        case .specialValues:
            .truncation
        case .truncation:
            .integralBinarySearch
        case .integralBinarySearch:
            .ratioBinarySearch
        case .ratioBinarySearch:
            nil
        }

        if let next = nextStage {
            stage = next
            batchIndex = 0
            batchCandidates = []
            needsFirstProbe = true
            guard currentTargetIndex < targets.count else { return false }
            prepareStage()
            return true
        }

        // All stages exhausted for this target — move to next.
        currentTargetIndex += 1
        stage = .specialValues
        batchIndex = 0
        batchCandidates = []
        needsFirstProbe = true
        if currentTargetIndex < targets.count {
            prepareStage()
        }
        return currentTargetIndex < targets.count
    }

    // MARK: - Helpers

    private func floatingChoice(
        from value: Double,
        tag: TypeTag,
        allowNonFinite: Bool = false
    ) -> ChoiceValue? {
        switch tag {
        case .double:
            guard allowNonFinite || value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard allowNonFinite || narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        case .float16:
            let encoded = Float16Emulation.encodedBitPattern(from: value)
            let reconstructed = Float16Emulation.doubleValue(fromEncoded: encoded)
            guard allowNonFinite || reconstructed.isFinite else { return nil }
            return .floating(reconstructed, encoded, .float16)
        default:
            return nil
        }
    }

    private func makeChoice(bitPattern: UInt64, tag: TypeTag) -> ChoiceValue? {
        ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
    }

    private func floorDivMod(
        _ numerator: Int64,
        _ denominator: Int64
    ) -> (quotient: Int64, remainder: Int64) {
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
