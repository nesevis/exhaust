//
//  FloatSearch+Probing.swift
//  Exhaust
//

// MARK: - Stages

extension FloatSearch {
    /// Collects the scope's float leaves and starts at the special-values stage of the first one, which the first pull prepares.
    static func initialState(
        scope: FloatMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        tuning: ReductionTuning
    ) -> State {
        var targets: [Target] = []

        for entry in scope.leaves {
            let nodeID = entry.nodeID
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            guard let range = graph.nodes[nodeID].positionRange else {
                continue
            }
            guard metadata.value.tag.isFloatingPoint else {
                continue
            }
            targets.append(Target(
                nodeID: nodeID,
                sequenceIndex: range.lowerBound,
                typeTag: metadata.typeTag,
                validRange: metadata.validRange,
                isRangeExplicit: metadata.isRangeExplicit,
                currentValue: metadata.value.decodedDoubleValue,
                currentBitPattern: metadata.value.bitPattern64,
                mayReshape: entry.mayReshapeOnAcceptance
            ))
        }

        return State(
            sequence: sequence,
            targets: targets,
            currentTargetIndex: 0,
            stage: .specialValues,
            batchCandidates: [],
            batchIndex: 0,
            stepper: FindIntegerStepper(),
            searchStepper: nil,
            interpolationBinaryThreshold: tuning.interpolationBinaryThreshold,
            interpolationInitialDivisor: tuning.interpolationInitialDivisor,
            needsFirstProbe: true,
            binarySearchMinDelta: 1,
            binarySearchMaxQuantum: 0,
            binarySearchMovesUp: false,
            binarySearchCurrentInt: 0,
            ratioDenominator: 0,
            ratioRemainder: 0,
            ratioIntegerPart: 0,
            ratioDistance: 0
        )
    }

    /// Advances through the five-stage float pipeline, returning the next probe candidate or nil when all stages and targets are exhausted.
    static func nextProbe(
        state: inout State,
        lastAccepted: Bool
    ) -> ReductionCandidate? {
        while state.currentTargetIndex < state.targets.count {
            if state.needsFirstProbe {
                state.needsFirstProbe = false
                prepareStage(state: &state)
            } else if lastAccepted {
                handleAcceptance(state: &state)
                if state.needsFirstProbe {
                    // A batch acceptance advances the leaf; its successor needs its own candidates before another probe.
                    continue
                }
            }

            if let candidate = nextCandidateForCurrentStage(
                state: &state,
                lastAccepted: lastAccepted
            ) {
                return candidate
            }

            // Stage exhausted: advance to the next stage or the next target.
            if advanceStageOrTarget(state: &state) == false {
                return nil
            }
        }
        return nil
    }

    // MARK: - Stage Preparation

    /// Prepares the current stage for the current target: its batch candidates, or its binary search bounds.
    static func prepareStage(state: inout State) {
        guard state.currentTargetIndex < state.targets.count else {
            return
        }
        let target = state.targets[state.currentTargetIndex]
        state.batchCandidates = []
        state.batchIndex = 0

        switch state.stage {
            case .specialValues:
                prepareSpecialValues(state: &state, target: target)
            case .boundaries:
                state.batchCandidates = FloatReduction.boundaryCandidates(for: target.currentValue, tag: target.typeTag)
            case .precisionWalk:
                preparePrecisionWalk(state: &state, target: target)
            case .integralBinarySearch:
                prepareIntegralBinarySearch(state: &state, target: target)
            case .ratioBinarySearch:
                prepareRatioBinarySearch(state: &state, target: target)
        }
    }

    /// Tries the reduction target and the positive counterpart before special magnitudes, allowing a sign-only simplification even for integral floats that skip precision search.
    static func prepareSpecialValues(state: inout State, target: Target) {
        var seen = Set<UInt64>()
        seen.insert(target.currentBitPattern)
        var candidates: [UInt64] = []

        guard target.sequenceIndex < state.sequence.count,
              let entry = state.sequence[target.sequenceIndex].value
        else {
            return
        }
        let isWithinRecordedRange = entry.isRangeExplicit && entry.choice.fits(in: entry.validRange)
        let targetBitPattern = isWithinRecordedRange
            ? entry.choice.reductionTarget(in: entry.validRange)
            : entry.choice.semanticSimplest.bitPattern64
        if seen.insert(targetBitPattern).inserted {
            candidates.append(targetBitPattern)
        }

        if entry.choice.hasNegativeSign,
           let positive = entry.choice.signFlipped,
           seen.insert(positive.bitPattern64).inserted
        {
            candidates.append(positive.bitPattern64)
        }

        for special in FloatReduction.specialValues(for: target.typeTag) {
            guard let candidateChoice = target.typeTag.floatingChoice(
                from: special,
                allowNonFinite: true
            ) else {
                continue
            }
            let bitPattern = candidateChoice.bitPattern64
            if seen.insert(bitPattern).inserted {
                candidates.append(bitPattern)
            }
        }

        state.batchCandidates = candidates
    }

    /// Arms a grid walk for a fractional leaf, leaving the walk nil for an integral or non-finite one. Like the boundary batch before it, each grid's candidates include adjacent representations, preserving failures that rounding to the grid would erase.
    static func preparePrecisionWalk(state: inout State, target: Target) {
        guard let finestGrid = FloatReduction.finestGrid(of: target.currentValue) else {
            return
        }
        var walk = PrecisionWalk(origin: target.currentValue, finestGrid: finestGrid, tag: target.typeTag)
        walk.begin(step: state.stepper.start())
        state.precisionWalk = walk
    }

    /// Sets up binary search toward the integer target for a leaf whose value is already integral, stepping in multiples of the value's ULP so every probe is representable in the leaf's type. Does nothing for a non-integral value, which the ratio stage handles.
    static func prepareIntegralBinarySearch(state: inout State, target: Target) {
        // `Int64(exactly:)` rejects both non-integral values and magnitudes outside Int64. Do not gate on `abs(...) <= Double(Int64.max)`: `Double(Int64.max)` rounds up to 2^63, so that test admits exactly 2^63, which then traps in the `Int64` conversion.
        guard target.currentValue.isFinite,
              let currentInt = Int64(exactly: target.currentValue)
        else {
            return
        }

        let targetInt = integerReductionTarget(target: target)
        let movesUp = targetInt > currentInt
        let distance = movesUp
            ? UInt64(targetInt - currentInt)
            : UInt64(currentInt - targetInt)
        guard distance > 1 else {
            return
        }

        let currentULP: Double = switch target.typeTag {
            case .double:
                target.currentValue.ulp
            case .float, .float16:
                Double(Float(target.currentValue).ulp)
            default:
                1.0
        }
        guard currentULP.isFinite else {
            return
        }
        let minDelta = UInt64(max(1.0, currentULP.rounded(.up)))
        guard minDelta > 0 else {
            return
        }
        let maxQuantum = distance / minDelta
        guard maxQuantum > 0 else {
            return
        }

        state.binarySearchMinDelta = minDelta
        state.binarySearchMaxQuantum = maxQuantum
        state.binarySearchMovesUp = movesUp
        state.binarySearchCurrentInt = currentInt
        state.searchStepper = towardTarget(distance: maxQuantum, state: state)
    }

    /// Sets up binary search over the integer part of the float's rational decomposition, preserving the fractional remainder so the search moves through exact rational multiples.
    static func prepareRatioBinarySearch(state: inout State, target: Target) {
        guard target.currentValue.isFinite,
              abs(target.currentValue) <= FloatReduction.maxPreciseInteger(for: target.typeTag),
              let ratio = FloatReduction.integerRatio(for: target.currentValue, tag: target.typeTag)
        else {
            return
        }

        guard ratio.denominator > 1, ratio.denominator <= UInt64(Int64.max) else {
            return
        }

        let denominator = Int64(ratio.denominator)
        let (integerPart, remainder) = floorDivMod(ratio.numerator, denominator)
        let targetInt = integerReductionTarget(target: target)
        let movesUp = targetInt > integerPart
        let distance = movesUp
            ? UInt64(targetInt - integerPart)
            : UInt64(integerPart - targetInt)
        guard distance > 0 else {
            return
        }

        state.ratioDenominator = denominator
        state.ratioRemainder = remainder
        state.ratioIntegerPart = integerPart
        state.ratioDistance = distance
        state.binarySearchMovesUp = movesUp
        state.searchStepper = towardTarget(distance: distance, state: state)
    }

    /// Searches step counts from zero, the current value, up to `distance`, the target, for the largest that still fails. Probing from the target end finds a distant failure that a search anchored at the current value would stop short of after its first pass.
    private static func towardTarget(distance: UInt64, state: State) -> DirectionalStepper {
        DirectionalStepper(
            lo: 0,
            hi: distance,
            direction: .findLargest,
            binaryThreshold: state.interpolationBinaryThreshold,
            initialDivisor: state.interpolationInitialDivisor
        )
    }

    // MARK: - Candidate Generation

    /// Dispatches to the current stage's candidate generator, returning the next probe or nil when the stage is exhausted.
    static func nextCandidateForCurrentStage(
        state: inout State,
        lastAccepted: Bool
    ) -> ReductionCandidate? {
        switch state.stage {
            case .specialValues, .boundaries:
                nextBatchCandidate(state: &state)
            case .precisionWalk:
                nextPrecisionWalkCandidate(state: &state, lastAccepted: lastAccepted)
            case .integralBinarySearch:
                nextIntegralBinarySearchCandidate(state: &state, lastAccepted: lastAccepted)
            case .ratioBinarySearch:
                nextRatioBinarySearchCandidate(state: &state, lastAccepted: lastAccepted)
        }
    }

    /// Generates a batch candidate by applying the next pre-computed bit pattern from ``State/batchCandidates`` to the current target, skipping candidates that are out of range or not shortlex-smaller.
    static func nextBatchCandidate(state: inout State) -> ReductionCandidate? {
        guard state.currentTargetIndex < state.targets.count else {
            return nil
        }
        let target = state.targets[state.currentTargetIndex]
        while state.batchIndex < state.batchCandidates.count {
            let bitPattern = state.batchCandidates[state.batchIndex]
            state.batchIndex += 1
            guard let candidate = candidateProbe(bitPattern: bitPattern, target: target, sequence: state.sequence) else {
                continue
            }
            return candidate
        }
        return nil
    }

    /// Pulls the next grid probe. Each stepper step tries its grid's candidates until one is accepted or all are rejected, and a grid whose candidates were all rejected answers the stepper as an accepted step.
    static func nextPrecisionWalkCandidate(
        state: inout State,
        lastAccepted: Bool
    ) -> ReductionCandidate? {
        guard var walk = state.precisionWalk else {
            return nil
        }
        if walk.outstandingBitPattern != nil {
            walk.outstandingBitPattern = nil
            walk.gridFails = lastAccepted
        }
        let target = state.targets[state.currentTargetIndex]
        while true {
            while walk.gridFails == false, walk.candidateIndex < walk.candidates.count {
                let bitPattern = walk.candidates[walk.candidateIndex]
                walk.candidateIndex += 1
                guard let candidate = candidateProbe(bitPattern: bitPattern, target: target, sequence: state.sequence) else {
                    continue
                }
                walk.outstandingBitPattern = bitPattern
                state.precisionWalk = walk
                return candidate
            }
            guard let step = state.stepper.advance(lastAccepted: walk.gridFails == false) else {
                state.precisionWalk = nil
                return nil
            }
            walk.begin(step: step)
        }
    }

    /// The sparse edit setting the target to `bitPattern`, or nil when the pattern is outside an explicit range or does not precede the current entry.
    static func candidateProbe(
        bitPattern: UInt64,
        target: Target,
        sequence: ChoiceSequence
    ) -> ReductionCandidate? {
        guard let candidateChoice = makeChoice(bitPattern: bitPattern, tag: target.typeTag) else {
            return nil
        }
        if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
            return nil
        }

        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        guard candidateEntry.shortLexCompare(sequence[target.sequenceIndex]) == .lt else {
            return nil
        }

        return target.lazyProbe(replacing: candidateEntry, in: sequence)
    }

    /// Generates the next binary search probe for integral reduction, stepping through ULP-aligned quanta via ``DirectionalStepper`` and recording convergence when the stepper is exhausted.
    static func nextIntegralBinarySearchCandidate(
        state: inout State,
        lastAccepted: Bool
    ) -> ReductionCandidate? {
        guard state.searchStepper != nil else {
            return nil
        }
        let target = state.targets[state.currentTargetIndex]

        var accepted = lastAccepted
        while true {
            let quantum: UInt64?
            if state.batchIndex == 0 {
                state.batchIndex = 1
                quantum = state.searchStepper?.start()
            } else {
                quantum = state.searchStepper?.advance(lastAccepted: accepted)
            }

            guard let unsignedStepCount = quantum else {
                if state.searchStepper?.bestAccepted ?? 0 > 0 {
                    refreshTargetFromBaseline(state: &state)
                }
                state.convergenceStore[target.nodeID] = ConvergedOrigin(
                    bound: state.targets[state.currentTargetIndex].currentBitPattern,
                    signal: .monotoneConvergence,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
                return nil
            }

            guard unsignedStepCount <= state.binarySearchMaxQuantum else {
                accepted = false
                continue
            }
            let delta = unsignedStepCount * state.binarySearchMinDelta
            guard delta <= UInt64(Int64.max) else {
                accepted = false
                continue
            }
            let signedDelta = Int64(delta)
            let candidateInt = state.binarySearchMovesUp
                ? state.binarySearchCurrentInt + signedDelta
                : state.binarySearchCurrentInt - signedDelta
            let candidateDouble = Double(candidateInt)
            guard let candidateChoice = target.typeTag.floatingChoice(from: candidateDouble) else {
                accepted = false
                continue
            }

            if candidateChoice.bitPattern64 == target.currentBitPattern {
                accepted = true
                continue
            }

            if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
                accepted = false
                continue
            }

            let candidateEntry = ChoiceSequenceValue.value(.init(
                choice: candidateChoice,
                validRange: target.validRange,
                isRangeExplicit: target.isRangeExplicit
            ))
            guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
                accepted = false
                continue
            }

            return target.lazyProbe(replacing: candidateEntry, in: state.sequence)
        }
    }

    /// Generates the next binary search probe for ratio-based reduction, reconstructing exact rational values from the stepped integer part and fixed remainder.
    static func nextRatioBinarySearchCandidate(
        state: inout State,
        lastAccepted: Bool
    ) -> ReductionCandidate? {
        guard state.searchStepper != nil else {
            return nil
        }
        let target = state.targets[state.currentTargetIndex]

        var accepted = lastAccepted
        while true {
            let quantum: UInt64?
            if state.batchIndex == 0 {
                state.batchIndex = 1
                quantum = state.searchStepper?.start()
            } else {
                quantum = state.searchStepper?.advance(lastAccepted: accepted)
            }

            guard let unsignedStepCount = quantum else {
                if state.searchStepper?.bestAccepted ?? 0 > 0 {
                    refreshTargetFromBaseline(state: &state)
                }
                state.convergenceStore[target.nodeID] = ConvergedOrigin(
                    bound: state.targets[state.currentTargetIndex].currentBitPattern,
                    signal: .monotoneConvergence,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
                return nil
            }

            guard unsignedStepCount <= state.ratioDistance, unsignedStepCount <= UInt64(Int64.max) else {
                accepted = false
                continue
            }
            let signedDelta = Int64(unsignedStepCount)
            let candidateInteger = state.binarySearchMovesUp
                ? state.ratioIntegerPart + signedDelta
                : state.ratioIntegerPart - signedDelta

            let (scaledNumerator, multiplyOverflow) =
                candidateInteger.multipliedReportingOverflow(by: state.ratioDenominator)
            guard multiplyOverflow == false else {
                accepted = false
                continue
            }
            let (candidateNumerator, addOverflow) =
                scaledNumerator.addingReportingOverflow(state.ratioRemainder)
            guard addOverflow == false else {
                accepted = false
                continue
            }

            let candidateValue = Double(candidateNumerator) / Double(state.ratioDenominator)
            guard let candidateChoice = target.typeTag.floatingChoice(from: candidateValue) else {
                accepted = false
                continue
            }

            if candidateChoice.bitPattern64 == target.currentBitPattern {
                accepted = true
                continue
            }

            if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
                accepted = false
                continue
            }

            let candidateEntry = ChoiceSequenceValue.value(.init(
                choice: candidateChoice,
                validRange: target.validRange,
                isRangeExplicit: target.isRangeExplicit
            ))
            guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
                accepted = false
                continue
            }

            return target.lazyProbe(replacing: candidateEntry, in: state.sequence)
        }
    }

    // MARK: - Acceptance & Advancement

    /// Processes an accepted probe by updating the current target's value and bit pattern, then advancing to the next target for batch stages, continuing the grid walk, or deferring to the stepper for binary search stages.
    static func handleAcceptance(state: inout State) {
        switch state.stage {
            case .specialValues, .boundaries:
                // The last batch candidate was accepted: record it, then restart from the first stage on the next target.
                refreshTargetFromBaseline(state: &state)
                state.currentTargetIndex += 1
                state.stage = .specialValues
                state.needsFirstProbe = true
            case .precisionWalk:
                // A grid probe was accepted: record it and keep searching coarser grids. The walk reads the acceptance on its next pull.
                if state.precisionWalk?.outstandingBitPattern != nil {
                    refreshTargetFromBaseline(state: &state)
                }
            case .integralBinarySearch, .ratioBinarySearch:
                // Stepper handles acceptance via advance(lastAccepted:).
                break
        }
    }

    /// Moves to the next stage for the current target, or advances to the next leaf target when all five stages are exhausted, returning false when no targets remain. The stage is prepared by the next call to ``nextProbe(state:lastAccepted:)``, which sees `needsFirstProbe`.
    @discardableResult
    static func advanceStageOrTarget(state: inout State) -> Bool {
        let nextStage: Stage? = switch state.stage {
            case .specialValues:
                .boundaries
            case .boundaries:
                .precisionWalk
            case .precisionWalk:
                .integralBinarySearch
            case .integralBinarySearch:
                .ratioBinarySearch
            case .ratioBinarySearch:
                nil
        }

        if let next = nextStage {
            state.stage = next
            state.batchIndex = 0
            state.batchCandidates = []
            state.stepper = FindIntegerStepper()
            state.searchStepper = nil
            state.needsFirstProbe = true
            return state.currentTargetIndex < state.targets.count
        }

        // All stages exhausted for this target: move to the next one.
        state.currentTargetIndex += 1
        state.stage = .specialValues
        state.batchIndex = 0
        state.batchCandidates = []
        state.stepper = FindIntegerStepper()
        state.searchStepper = nil
        state.needsFirstProbe = true
        return state.currentTargetIndex < state.targets.count
    }

    // MARK: - Helpers

    /// Uses the recovered baseline already adopted by ``next(_:into:)``; rewriting the proposed value here could undo a decoder adjustment and invalidate sparse probe hashes.
    static func refreshTargetFromBaseline(state: inout State) {
        let position = state.targets[state.currentTargetIndex].sequenceIndex
        guard let choice = state.sequence[position].value?.choice else {
            return
        }
        if choice.tag.isFloatingPoint {
            state.targets[state.currentTargetIndex].currentValue = choice.decodedDoubleValue
        }
        state.targets[state.currentTargetIndex].currentBitPattern = choice.bitPattern64
    }

    static func makeChoice(bitPattern: UInt64, tag: TypeTag) -> ChoiceValue? {
        ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
    }

    static func floorDivMod(
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

    private static func integerReductionTarget(target: Target) -> Int64 {
        guard target.isRangeExplicit, let validRange = target.validRange else {
            return 0
        }
        let targetBitPattern = ChoiceValue(target.currentBitPattern, tag: target.typeTag)
            .reductionTarget(in: validRange)
        let targetValue = target.typeTag.numericDoubleValue(forBitPattern: targetBitPattern)
        // See `prepareIntegralBinarySearch`: `Double(Int64.max)` rounds to 2^63, so an `abs(...) <= Double(Int64.max)` gate would admit 2^63 and trap. `Int64(exactly:)` on the truncated value cannot overflow.
        guard targetValue.isFinite,
              let truncated = Int64(exactly: targetValue.rounded(.towardZero))
        else {
            return 0
        }
        return truncated
    }
}
