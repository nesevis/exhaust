//
//  GraphValueEncoder+Float.swift
//  Exhaust
//

// MARK: - Float Mode

extension GraphValueEncoder {
    mutating func startFloat(
        scope: FloatMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        preservingConvergence: [Int: ConvergedOrigin] = [:]
    ) {
        var targets: [FloatTarget] = []

        for entry in scope.leaves {
            let nodeID = entry.nodeID
            if preservingConvergence[nodeID] != nil { continue }
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            guard case let .floating(currentValue, currentBitPattern, _) = metadata.value else { continue }
            targets.append(FloatTarget(
                nodeID: nodeID,
                sequenceIndex: range.lowerBound,
                typeTag: metadata.typeTag,
                validRange: metadata.validRange,
                isRangeExplicit: metadata.isRangeExplicit,
                currentValue: currentValue,
                currentBitPattern: currentBitPattern,
                mayReshape: entry.mayReshapeOnAcceptance
            ))
        }

        mode = .floatLeaves(FloatState(
            sequence: sequence,
            targets: targets,
            currentTargetIndex: 0,
            stage: .specialValues,
            batchCandidates: [],
            batchIndex: 0,
            stepper: FindIntegerStepper(),
            needsFirstProbe: true,
            lastEmittedCandidate: nil,
            binarySearchMinDelta: 1,
            binarySearchMaxQuantum: 0,
            binarySearchMovesUp: false,
            binarySearchCurrentInt: 0,
            ratioDenominator: 0,
            ratioRemainder: 0,
            ratioIntegerPart: 0,
            ratioDistance: 0
        ))
    }

    mutating func nextFloatProbe(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        // Update baseline on acceptance.
        if lastAccepted, let accepted = state.lastEmittedCandidate {
            state.sequence = accepted
        }
        state.lastEmittedCandidate = nil

        while state.currentTargetIndex < state.targets.count {
            if state.needsFirstProbe {
                state.needsFirstProbe = false
                prepareFloatStage(state: &state)
            } else if lastAccepted {
                handleFloatAcceptance(state: &state)
            }

            if let candidate = nextFloatCandidateForCurrentStage(
                state: &state,
                lastAccepted: lastAccepted
            ) {
                state.lastEmittedCandidate = candidate
                return candidate
            }

            // Stage exhausted — advance to next stage or next target.
            if advanceFloatStageOrTarget(state: &state) == false {
                return nil
            }
        }
        return nil
    }

    // MARK: - Float Stage Preparation

    mutating func prepareFloatStage(state: inout FloatState) {
        guard state.currentTargetIndex < state.targets.count else { return }
        let target = state.targets[state.currentTargetIndex]
        state.batchCandidates = []
        state.batchIndex = 0

        switch state.stage {
        case .specialValues:
            prepareFloatSpecialValues(state: &state, target: target)
        case .truncation:
            prepareFloatTruncation(state: &state, target: target)
        case .integralBinarySearch:
            prepareFloatIntegralBinarySearch(state: &state, target: target)
        case .ratioBinarySearch:
            prepareFloatRatioBinarySearch(state: &state, target: target)
        }
    }

    mutating func prepareFloatSpecialValues(state: inout FloatState, target: FloatTarget) {
        var candidates: [UInt64] = []

        // Try the semantic-simplest target directly.
        guard target.sequenceIndex < state.sequence.count,
              let entry = state.sequence[target.sequenceIndex].value else { return }
        let isWithinRecordedRange = entry.isRangeExplicit && entry.choice.fits(in: entry.validRange)
        let targetBitPattern = isWithinRecordedRange
            ? entry.choice.reductionTarget(in: entry.validRange)
            : entry.choice.semanticSimplest.bitPattern64
        if targetBitPattern != target.currentBitPattern {
            candidates.append(targetBitPattern)
        }

        for special in FloatReduction.specialValues(for: target.typeTag) {
            guard let candidateChoice = floatingChoice(
                from: special,
                tag: target.typeTag,
                allowNonFinite: true
            ) else { continue }
            let bp = candidateChoice.bitPattern64
            if bp != target.currentBitPattern, candidates.contains(bp) == false {
                candidates.append(bp)
            }
        }

        state.batchCandidates = candidates
    }

    mutating func prepareFloatTruncation(state: inout FloatState, target: FloatTarget) {
        guard target.currentValue.isFinite else {
            state.batchCandidates = []
            return
        }

        var seenBitPatterns = Set<UInt64>()
        var candidates: [UInt64] = []

        for power in 0 ..< 10 {
            let scale = Double(1 << power)
            let scaled = target.currentValue * scale
            guard scaled.isFinite else { continue }

            for truncated in [scaled.rounded(.down), scaled.rounded(.up)] {
                let candidateValue = truncated / scale
                guard candidateValue.isFinite,
                      let candidateChoice = floatingChoice(from: candidateValue, tag: target.typeTag)
                else { continue }
                let bp = candidateChoice.bitPattern64
                guard bp != target.currentBitPattern,
                      seenBitPatterns.insert(bp).inserted
                else { continue }
                candidates.append(bp)
            }
        }

        state.batchCandidates = candidates
    }

    mutating func prepareFloatIntegralBinarySearch(state: inout FloatState, target: FloatTarget) {
        guard target.currentValue.isFinite,
              target.currentValue == target.currentValue.rounded(.towardZero),
              abs(target.currentValue) <= Double(Int64.max)
        else { return }

        let currentInt = Int64(target.currentValue)
        let targetInt: Int64 = 0
        let movesUp = targetInt > currentInt
        let distance = movesUp
            ? UInt64(targetInt - currentInt)
            : UInt64(currentInt - targetInt)
        guard distance > 1 else { return }

        let currentULP: Double = switch target.typeTag {
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

        state.binarySearchMinDelta = minDelta
        state.binarySearchMaxQuantum = maxQuantum
        state.binarySearchMovesUp = movesUp
        state.binarySearchCurrentInt = currentInt
    }

    mutating func prepareFloatRatioBinarySearch(state: inout FloatState, target: FloatTarget) {
        guard target.currentValue.isFinite,
              abs(target.currentValue) <= FloatReduction.maxPreciseInteger(for: target.typeTag),
              let ratio = FloatReduction.integerRatio(for: target.currentValue, tag: target.typeTag)
        else { return }

        guard ratio.denominator > 1, ratio.denominator <= UInt64(Int64.max) else { return }

        let denominator = Int64(ratio.denominator)
        let (integerPart, remainder) = floorDivMod(ratio.numerator, denominator)
        let targetInt: Int64 = 0
        let movesUp = targetInt > integerPart
        let distance = movesUp
            ? UInt64(targetInt - integerPart)
            : UInt64(integerPart - targetInt)
        guard distance > 0 else { return }

        state.ratioDenominator = denominator
        state.ratioRemainder = remainder
        state.ratioIntegerPart = integerPart
        state.ratioDistance = distance
        state.binarySearchMovesUp = movesUp
    }

    // MARK: - Float Candidate Generation

    mutating func nextFloatCandidateForCurrentStage(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        switch state.stage {
        case .specialValues, .truncation:
            nextFloatBatchCandidate(state: &state)
        case .integralBinarySearch:
            nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: lastAccepted)
        case .ratioBinarySearch:
            nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: lastAccepted)
        }
    }

    mutating func nextFloatBatchCandidate(state: inout FloatState) -> ChoiceSequence? {
        guard state.currentTargetIndex < state.targets.count else { return nil }
        let target = state.targets[state.currentTargetIndex]
        while state.batchIndex < state.batchCandidates.count {
            let bp = state.batchCandidates[state.batchIndex]
            state.batchIndex += 1

            guard let candidateChoice = makeFloatChoice(bitPattern: bp, tag: target.typeTag) else {
                continue
            }
            if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
                continue
            }

            let candidateEntry = ChoiceSequenceValue.value(.init(
                choice: candidateChoice,
                validRange: target.validRange,
                isRangeExplicit: target.isRangeExplicit
            ))
            guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
                continue
            }

            var candidate = state.sequence
            candidate[target.sequenceIndex] = candidateEntry
            return candidate
        }
        return nil
    }

    mutating func nextFloatIntegralBinarySearchCandidate(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard state.binarySearchMaxQuantum > 0 else { return nil }
        let target = state.targets[state.currentTargetIndex]

        let quantum: Int?
        if state.batchIndex == 0 {
            state.batchIndex = 1
            quantum = state.stepper.start()
        } else {
            quantum = state.stepper.advance(lastAccepted: lastAccepted)
        }

        guard let k = quantum else {
            // Converged — apply best accepted if any.
            if state.stepper.bestAccepted > 0 {
                applyFloatIntegralBinarySearchBest(state: &state)
            }
            convergenceStore[target.nodeID] = ConvergedOrigin(
                bound: state.targets[state.currentTargetIndex].currentBitPattern,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
            return nil
        }

        let kU64 = UInt64(k)
        guard kU64 <= state.binarySearchMaxQuantum else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let delta = kU64 * state.binarySearchMinDelta
        guard delta <= UInt64(Int64.max) else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let signedDelta = Int64(delta)
        let candidateInt = state.binarySearchMovesUp
            ? state.binarySearchCurrentInt + signedDelta
            : state.binarySearchCurrentInt - signedDelta
        let candidateDouble = Double(candidateInt)
        guard let candidateChoice = floatingChoice(from: candidateDouble, tag: target.typeTag) else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        if candidateChoice.bitPattern64 == target.currentBitPattern {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: true)
        }

        if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        var candidate = state.sequence
        candidate[target.sequenceIndex] = candidateEntry
        return candidate
    }

    mutating func applyFloatIntegralBinarySearchBest(state: inout FloatState) {
        let target = state.targets[state.currentTargetIndex]
        let bestK = UInt64(state.stepper.bestAccepted)
        let delta = bestK * state.binarySearchMinDelta
        let signedDelta = Int64(delta)
        let candidateInt = state.binarySearchMovesUp
            ? state.binarySearchCurrentInt + signedDelta
            : state.binarySearchCurrentInt - signedDelta
        let candidateDouble = Double(candidateInt)
        guard let candidateChoice = floatingChoice(from: candidateDouble, tag: target.typeTag) else {
            return
        }
        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        state.sequence[target.sequenceIndex] = candidateEntry
        state.targets[state.currentTargetIndex].currentValue = candidateDouble
        state.targets[state.currentTargetIndex].currentBitPattern = candidateChoice.bitPattern64
    }

    mutating func nextFloatRatioBinarySearchCandidate(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard state.ratioDistance > 0 else { return nil }
        let target = state.targets[state.currentTargetIndex]

        let quantum: Int?
        if state.batchIndex == 0 {
            state.batchIndex = 1
            quantum = state.stepper.start()
        } else {
            quantum = state.stepper.advance(lastAccepted: lastAccepted)
        }

        guard let k = quantum else {
            if state.stepper.bestAccepted > 0 {
                applyFloatRatioBinarySearchBest(state: &state)
            }
            convergenceStore[target.nodeID] = ConvergedOrigin(
                bound: state.targets[state.currentTargetIndex].currentBitPattern,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
            return nil
        }

        let kU64 = UInt64(k)
        guard kU64 <= state.ratioDistance, kU64 <= UInt64(Int64.max) else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let signedDelta = Int64(kU64)
        let candidateInteger = state.binarySearchMovesUp
            ? state.ratioIntegerPart + signedDelta
            : state.ratioIntegerPart - signedDelta

        let (scaledNumerator, multiplyOverflow) =
            candidateInteger.multipliedReportingOverflow(by: state.ratioDenominator)
        guard multiplyOverflow == false else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let (candidateNumerator, addOverflow) =
            scaledNumerator.addingReportingOverflow(state.ratioRemainder)
        guard addOverflow == false else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        let candidateValue = Double(candidateNumerator) / Double(state.ratioDenominator)
        guard let candidateChoice = floatingChoice(from: candidateValue, tag: target.typeTag) else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        if candidateChoice.bitPattern64 == target.currentBitPattern {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: true)
        }

        if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        var candidate = state.sequence
        candidate[target.sequenceIndex] = candidateEntry
        return candidate
    }

    mutating func applyFloatRatioBinarySearchBest(state: inout FloatState) {
        let target = state.targets[state.currentTargetIndex]
        let bestK = UInt64(state.stepper.bestAccepted)
        let signedDelta = Int64(bestK)
        let candidateInteger = state.binarySearchMovesUp
            ? state.ratioIntegerPart + signedDelta
            : state.ratioIntegerPart - signedDelta

        let scaledNumerator = candidateInteger * state.ratioDenominator
        let candidateNumerator = scaledNumerator + state.ratioRemainder
        let candidateValue = Double(candidateNumerator) / Double(state.ratioDenominator)
        guard let candidateChoice = floatingChoice(from: candidateValue, tag: target.typeTag) else {
            return
        }
        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        state.sequence[target.sequenceIndex] = candidateEntry
        state.targets[state.currentTargetIndex].currentValue = candidateValue
        state.targets[state.currentTargetIndex].currentBitPattern = candidateChoice.bitPattern64
    }

    // MARK: - Float Acceptance & Advancement

    mutating func handleFloatAcceptance(state: inout FloatState) {
        let target = state.targets[state.currentTargetIndex]
        switch state.stage {
        case .specialValues, .truncation:
            // Batch stages: the last emitted candidate was accepted.
            // Update target and restart from stage 0 on the next target.
            let bp = state.batchCandidates[state.batchIndex - 1]
            if let choice = makeFloatChoice(bitPattern: bp, tag: target.typeTag) {
                let entry = ChoiceSequenceValue.value(.init(
                    choice: choice,
                    validRange: target.validRange,
                    isRangeExplicit: target.isRangeExplicit
                ))
                state.sequence[target.sequenceIndex] = entry
                if case let .floating(value, _, _) = choice {
                    state.targets[state.currentTargetIndex].currentValue = value
                }
                state.targets[state.currentTargetIndex].currentBitPattern = bp
            }
            state.currentTargetIndex += 1
            state.stage = .specialValues
            state.needsFirstProbe = true
        case .integralBinarySearch, .ratioBinarySearch:
            // Stepper handles acceptance via advance(lastAccepted:).
            break
        }
    }

    @discardableResult
    mutating func advanceFloatStageOrTarget(state: inout FloatState) -> Bool {
        let nextStage: FloatStage? = switch state.stage {
        case .specialValues: .truncation
        case .truncation: .integralBinarySearch
        case .integralBinarySearch: .ratioBinarySearch
        case .ratioBinarySearch: nil
        }

        if let next = nextStage {
            state.stage = next
            state.batchIndex = 0
            state.batchCandidates = []
            state.stepper = FindIntegerStepper()
            state.needsFirstProbe = true
            guard state.currentTargetIndex < state.targets.count else { return false }
            prepareFloatStage(state: &state)
            return true
        }

        // All stages exhausted for this target — move to next.
        state.currentTargetIndex += 1
        state.stage = .specialValues
        state.batchIndex = 0
        state.batchCandidates = []
        state.stepper = FindIntegerStepper()
        state.needsFirstProbe = true
        if state.currentTargetIndex < state.targets.count {
            prepareFloatStage(state: &state)
        }
        return state.currentTargetIndex < state.targets.count
    }

    // MARK: - Float Helpers

    func floatingChoice(
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

    func makeFloatChoice(bitPattern: UInt64, tag: TypeTag) -> ChoiceValue? {
        ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
    }

    func floorDivMod(
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
