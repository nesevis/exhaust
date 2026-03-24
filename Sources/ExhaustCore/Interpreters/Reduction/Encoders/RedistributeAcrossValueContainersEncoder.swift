//
//  RedistributeAcrossValueContainersEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Cross-container value redistribution encoder.
///
/// For each pair of numeric values in the sequence, tries to decrease one value (toward its reduction target) while increasing the other by the same amount. Supports same-tag integer pairs, same-tag float pairs (via rational arithmetic), and cross-type float+integer pairs (mixed redistribution).
///
/// Uses ``FindIntegerStepper`` for feedback-driven delta search.
public struct RedistributeAcrossValueContainersEncoder: ComposableEncoder {
    public init() {}

    public let name: EncoderName = .redistributeArbitraryValuePairsAcrossContainers
    public let phase = ReductionPhase.redistribution

    // MARK: - Dual conformance disambiguation

    public var convergenceRecords: [Int: ConvergedOrigin] { [:] }

    // MARK: - ComposableEncoder

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        let spanCount = Self.extractFilteredSpans(from: sequence, in: positionRange, context: context).count
        guard spanCount >= 2 else { return nil }
        return min(spanCount * (spanCount - 1), 240) * 20
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        self.sequence = sequence
        semanticStats = SequenceSemanticStats(sequence: sequence)
        orientations = []
        orientationIndex = 0
        needsFirstProbe = true
        resetMonotoneState()

        // Extract all numeric values.
        var candidates = [NumericCandidate]()
        var i = 0
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while i < sequence.count {
            let entry = sequence[i]
            switch entry {
            case let .value(v), let .reduced(v):
                switch v.choice {
                case .unsigned, .signed, .floating:
                    candidates.append(NumericCandidate(index: i, value: v))
                }
            default:
                break
            }
            i += 1
        }

        // Cost is O(v² × probes_per_pair). The estimatedCost cap at 240 pairs × 20
        // probes already limits total work; no need to gate on candidate count.

        // Build all pair orientations.
        var ci = 0
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while ci < candidates.count {
            var cj = ci + 1
            while cj < candidates.count {
                // Try both orientations so index ordering does not block useful redistributions.
                for (lhs, rhs) in [(ci, cj), (cj, ci)] {
                    if let orientation = makeOrientation(
                        lhs: candidates[lhs],
                        rhs: candidates[rhs],
                        sequence: sequence
                    ) {
                        orientations.append(orientation)
                    }
                }
                cj += 1
            }
            ci += 1
        }

        // Largest-distance orientations first: high-impact consolidation pairs
        // get probed before trivial distance=1 pairs.
        orientations.sort { $0.distance > $1.distance }
    }

    // MARK: - Internal types

    private struct NumericCandidate {
        let index: Int
        let value: ChoiceSequenceValue.Value
    }

    private struct FloatRedistributionContext {
        let lhsNumerator: Int64
        let rhsNumerator: Int64
        let denominator: UInt64
        let lhsMovesUpward: Bool
        let distance: UInt64
    }

    private struct MixedRedistributionContext {
        let lhsNumerator: Int64
        let rhsNumerator: Int64
        let denominator: UInt64
        let intStepSize: UInt64
        let lhsMovesUpward: Bool
        let distanceInSteps: UInt64
    }

    /// One orientation of a pair: lhs is the value being moved toward its target,
    /// rhs is the compensation side.
    private struct PairOrientation {
        let lhsIndex: Int
        let rhsIndex: Int
        let decrease1Upward: Bool
        let distance: UInt64
        let floatContext: FloatRedistributionContext?
        let mixedContext: MixedRedistributionContext?
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var semanticStats = SequenceSemanticStats(sequence: ChoiceSequence())
    private var orientations: [PairOrientation] = []
    private var orientationIndex = 0

    // Per-orientation state
    private var stepper = FindIntegerStepper()
    private var needsFirstProbe = true

    // Best result from the monotone search phase for the current orientation.
    private var bestMonotoneCandidate: ChoiceSequence?
    private var bestMonotoneEntry1: ChoiceSequenceValue?
    private var bestMonotoneEntry2: ChoiceSequenceValue?
    private var bestMonotoneNonSemanticCount = Int.max

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while orientationIndex < orientations.count {
            if let candidate = advanceCurrentOrientation(lastAccepted: lastAccepted) {
                return candidate
            }
            // Current orientation exhausted. Commit best result if any.
            commitBestResult()
            orientationIndex += 1
            needsFirstProbe = true
            resetMonotoneState()
        }
        return nil
    }

    // MARK: - Orientation construction

    private func makeOrientation(
        lhs: NumericCandidate,
        rhs: NumericCandidate,
        sequence _: ChoiceSequence
    ) -> PairOrientation? {
        let bp1 = lhs.value.choice.bitPattern64
        let target1 = lhs.value.choice.reductionTarget(
            in: lhs.value.isRangeExplicit ? lhs.value.validRange : nil
        )

        let floatCtx = makeFloatRedistributionContext(
            lhs: lhs.value.choice,
            rhs: rhs.value.choice,
            lhsTargetBitPattern: target1
        )
        let mixedCtx: MixedRedistributionContext? = floatCtx == nil
            ? makeMixedRedistributionContext(
                lhs: lhs.value.choice,
                rhs: rhs.value.choice,
                lhsTargetBitPattern: target1
            )
            : nil

        let decreaseUpward: Bool
        let distance: UInt64
        if let floatCtx {
            decreaseUpward = floatCtx.lhsMovesUpward
            distance = floatCtx.distance
        } else if let mixedCtx {
            decreaseUpward = mixedCtx.lhsMovesUpward
            distance = mixedCtx.distanceInSteps
        } else {
            // Same-tag integer pair.
            guard lhs.value.choice.tag == rhs.value.choice.tag else { return nil }
            guard bp1 != target1 else { return nil }
            decreaseUpward = target1 > bp1
            distance = decreaseUpward
                ? target1 - bp1
                : bp1 - target1
        }
        guard distance > 0 else { return nil }

        // Skip if rhs is already at its target — no room to compensate.
        let rhsSemanticDistance = absDiff(
            rhs.value.choice.shortlexKey,
            rhs.value.choice.semanticSimplest.shortlexKey
        )
        guard rhsSemanticDistance > 0 else { return nil }

        return PairOrientation(
            lhsIndex: lhs.index,
            rhsIndex: rhs.index,
            decrease1Upward: decreaseUpward,
            distance: distance,
            floatContext: floatCtx,
            mixedContext: mixedCtx
        )
    }

    // MARK: - Per-orientation advancement

    private mutating func advanceCurrentOrientation(lastAccepted: Bool) -> ChoiceSequence? {
        advanceMonotone(lastAccepted: lastAccepted)
    }

    // MARK: - Monotone phase (FindIntegerStepper)

    private mutating func advanceMonotone(lastAccepted: Bool) -> ChoiceSequence? {
        let orient = orientations[orientationIndex]

        // Re-read fresh values from the (possibly updated) sequence.
        guard let fresh1 = sequence[orient.lhsIndex].value,
              let fresh2 = sequence[orient.rhsIndex].value
        else {
            return nil
        }

        let k: Int
        if needsFirstProbe {
            needsFirstProbe = false
            k = stepper.start()
        } else {
            // Process acceptance of previous probe.
            if lastAccepted {
                recordMonotoneAcceptance()
            }
            guard let next = stepper.advance(lastAccepted: lastAccepted) else {
                return nil
            }
            k = next
        }

        let delta = UInt64(k)
        guard delta > 0, delta <= orient.distance else {
            // k=0 is trivially accepted by the stepper; produce no candidate but let it advance.
            if delta == 0 {
                return advanceMonotone(lastAccepted: true)
            }
            // delta > distance: reject and let stepper narrow.
            return advanceMonotone(lastAccepted: false)
        }

        return buildCandidate(
            orient: orient,
            fresh1: fresh1,
            fresh2: fresh2,
            delta: delta
        )
    }

    /// Records the best monotone candidate when the scheduler reports acceptance.
    private mutating func recordMonotoneAcceptance() {
        let orient = orientations[orientationIndex]
        let k = UInt64(stepper.bestAccepted)
        guard k > 0 else { return }

        guard let fresh1 = sequence[orient.lhsIndex].value,
              let fresh2 = sequence[orient.rhsIndex].value
        else { return }

        guard let (newChoice1, newChoice2) = computeNewChoices(
            orient: orient,
            fresh1: fresh1,
            fresh2: fresh2,
            delta: k
        ) else { return }

        let beforePair = sortedPairKeys(fresh1.choice, fresh2.choice)
        let afterPair = sortedPairKeys(newChoice1, newChoice2)

        // Only record if the pair multiset actually changed — avoid pure cross-container swaps.
        guard afterPair != beforePair else { return }

        let probeEntry1 = ChoiceSequenceValue.reduced(.init(
            choice: newChoice1,
            validRange: fresh1.validRange,
            isRangeExplicit: fresh1.isRangeExplicit
        ))
        let probeEntry2 = ChoiceSequenceValue.value(.init(
            choice: newChoice2,
            validRange: fresh2.validRange,
            isRangeExplicit: fresh2.isRangeExplicit
        ))
        let probeNonSemantic = semanticStats.nonSemanticCount(
            afterReplacing: (orient.lhsIndex, probeEntry1),
            and: (orient.rhsIndex, probeEntry2)
        )

        bestMonotoneCandidate = {
            var probe = sequence
            probe[orient.lhsIndex] = probeEntry1
            probe[orient.rhsIndex] = probeEntry2
            return probe
        }()
        bestMonotoneEntry1 = probeEntry1
        bestMonotoneEntry2 = probeEntry2
        bestMonotoneNonSemanticCount = probeNonSemantic
    }

    // MARK: - Candidate construction

    private func buildCandidate(
        orient: PairOrientation,
        fresh1: ChoiceSequenceValue.Value,
        fresh2: ChoiceSequenceValue.Value,
        delta: UInt64
    ) -> ChoiceSequence? {
        guard let (newChoice1, newChoice2) = computeNewChoices(
            orient: orient,
            fresh1: fresh1,
            fresh2: fresh2,
            delta: delta
        ) else { return nil }

        // Range validation for float and mixed pairs.
        if orient.floatContext != nil || orient.mixedContext != nil {
            if fresh1.isRangeExplicit, newChoice1.fits(in: fresh1.validRange) == false {
                return nil
            }
            if fresh2.isRangeExplicit, newChoice2.fits(in: fresh2.validRange) == false {
                return nil
            }
        }

        let probeEntry1 = ChoiceSequenceValue.reduced(.init(
            choice: newChoice1,
            validRange: fresh1.validRange,
            isRangeExplicit: fresh1.isRangeExplicit
        ))
        let probeEntry2 = ChoiceSequenceValue.value(.init(
            choice: newChoice2,
            validRange: fresh2.validRange,
            isRangeExplicit: fresh2.isRangeExplicit
        ))

        let currentNonSemanticCount = semanticStats.nonSemanticCount
        let probeNonSemanticCount = semanticStats.nonSemanticCount(
            afterReplacing: (orient.lhsIndex, probeEntry1),
            and: (orient.rhsIndex, probeEntry2)
        )

        let beforePair = sortedPairKeys(fresh1.choice, fresh2.choice)
        let afterPair = sortedPairKeys(newChoice1, newChoice2)

        // Improvement check: candidate must shortlex-precede current, reduce non-semantic
        // count, or improve the sorted pair keys.
        var probe = sequence
        probe[orient.lhsIndex] = probeEntry1
        probe[orient.rhsIndex] = probeEntry2

        let improvesStructure = probe.shortLexPrecedes(sequence)
            || probeNonSemanticCount < currentNonSemanticCount
            || afterPair.lexicographicallyPrecedes(beforePair)
        guard improvesStructure else { return nil }

        return probe
    }

    // MARK: - Commit best result

    private mutating func commitBestResult() {
        guard let probe = bestMonotoneCandidate,
              let entry1 = bestMonotoneEntry1,
              let entry2 = bestMonotoneEntry2
        else { return }

        let orient = orientations[orientationIndex]

        guard let fresh1 = sequence[orient.lhsIndex].value,
              let fresh2 = sequence[orient.rhsIndex].value
        else { return }

        let beforePair = sortedPairKeys(fresh1.choice, fresh2.choice)
        guard let afterEntry1Value = entry1.value,
              let afterEntry2Value = entry2.value
        else { return }
        let afterPair = sortedPairKeys(afterEntry1Value.choice, afterEntry2Value.choice)

        let currentNonSemanticCount = semanticStats.nonSemanticCount

        guard probe.shortLexPrecedes(sequence)
            || bestMonotoneNonSemanticCount < currentNonSemanticCount
            || afterPair.lexicographicallyPrecedes(beforePair)
        else { return }

        sequence = probe
        semanticStats.applyReplacements(
            (orient.lhsIndex, entry1),
            (orient.rhsIndex, entry2)
        )
    }

    // MARK: - State reset helpers

    private mutating func resetMonotoneState() {
        bestMonotoneCandidate = nil
        bestMonotoneEntry1 = nil
        bestMonotoneEntry2 = nil
        bestMonotoneNonSemanticCount = Int.max
    }

    // MARK: - Redistribution arithmetic

    /// Computes the new choice values for a pair after applying `delta` in the given orientation.
    private func computeNewChoices(
        orient: PairOrientation,
        fresh1: ChoiceSequenceValue.Value,
        fresh2: ChoiceSequenceValue.Value,
        delta: UInt64
    ) -> (ChoiceValue, ChoiceValue)? {
        if let mixedContext = orient.mixedContext {
            return mixedRedistributedPairChoices(
                lhs: fresh1.choice,
                rhs: fresh2.choice,
                delta: delta,
                context: mixedContext
            )
        }
        return redistributedPairChoices(
            lhs: fresh1.choice,
            rhs: fresh2.choice,
            delta: delta,
            lhsMovesUpward: orient.decrease1Upward,
            floatContext: orient.floatContext
        )
    }

    /// Computes redistributed choices for same-tag pairs (integer or float).
    ///
    /// For float pairs, operates in rational arithmetic space to preserve precision.
    /// For integer pairs, directly adjusts bit patterns.
    private func redistributedPairChoices(
        lhs: ChoiceValue,
        rhs: ChoiceValue,
        delta: UInt64,
        lhsMovesUpward: Bool,
        floatContext: FloatRedistributionContext?
    ) -> (ChoiceValue, ChoiceValue)? {
        if let floatContext {
            guard delta <= UInt64(Int64.max), delta <= floatContext.distance else {
                return nil
            }
            let signedDelta = Int64(delta)
            let lhsNumerator: Int64
            let rhsNumerator: Int64
            if lhsMovesUpward {
                let (lhsCandidate, lhsOverflow) = floatContext.lhsNumerator.addingReportingOverflow(signedDelta)
                let (rhsCandidate, rhsOverflow) = floatContext.rhsNumerator.subtractingReportingOverflow(signedDelta)
                guard lhsOverflow == false, rhsOverflow == false else { return nil }
                lhsNumerator = lhsCandidate
                rhsNumerator = rhsCandidate
            } else {
                let (lhsCandidate, lhsOverflow) = floatContext.lhsNumerator.subtractingReportingOverflow(signedDelta)
                let (rhsCandidate, rhsOverflow) = floatContext.rhsNumerator.addingReportingOverflow(signedDelta)
                guard lhsOverflow == false, rhsOverflow == false else { return nil }
                lhsNumerator = lhsCandidate
                rhsNumerator = rhsCandidate
            }

            let denominator = Double(floatContext.denominator)
            let lhsValue = Double(lhsNumerator) / denominator
            let rhsValue = Double(rhsNumerator) / denominator
            guard let newChoice1 = floatingChoice(from: lhsValue, tag: lhs.tag),
                  let newChoice2 = floatingChoice(from: rhsValue, tag: rhs.tag)
            else { return nil }
            return (newChoice1, newChoice2)
        }

        // Integer redistribution via bit patterns.
        guard let (newBP1, newBP2) = redistributedPairBitPatterns(
            lhsBitPattern: lhs.bitPattern64,
            rhsBitPattern: rhs.bitPattern64,
            delta: delta,
            lhsMovesUpward: lhsMovesUpward
        ) else { return nil }

        let newChoice1 = ChoiceValue(
            lhs.tag.makeConvertible(bitPattern64: newBP1),
            tag: lhs.tag
        )
        let newChoice2 = ChoiceValue(
            rhs.tag.makeConvertible(bitPattern64: newBP2),
            tag: rhs.tag
        )
        return (newChoice1, newChoice2)
    }

    /// Adjusts bit patterns for integer redistribution.
    private func redistributedPairBitPatterns(
        lhsBitPattern: UInt64,
        rhsBitPattern: UInt64,
        delta: UInt64,
        lhsMovesUpward: Bool
    ) -> (UInt64, UInt64)? {
        if lhsMovesUpward {
            guard UInt64.max - delta >= lhsBitPattern else { return nil }
            guard rhsBitPattern >= delta else { return nil }
            return (lhsBitPattern + delta, rhsBitPattern - delta)
        }

        guard lhsBitPattern >= delta else { return nil }
        guard UInt64.max - delta >= rhsBitPattern else { return nil }
        return (lhsBitPattern - delta, rhsBitPattern + delta)
    }

    /// Computes redistributed choices for cross-type (float+integer) pairs.
    ///
    /// Uses rational arithmetic with a common denominator to ensure integer constraints
    /// are satisfied (integer sides must receive whole-number deltas).
    private func mixedRedistributedPairChoices(
        lhs: ChoiceValue,
        rhs: ChoiceValue,
        delta: UInt64,
        context: MixedRedistributionContext
    ) -> (ChoiceValue, ChoiceValue)? {
        guard delta <= context.distanceInSteps else { return nil }

        let (actualDelta, stepOverflow) = delta.multipliedReportingOverflow(by: context.intStepSize)
        guard stepOverflow == false, actualDelta <= UInt64(Int64.max) else { return nil }
        let signedDelta = Int64(actualDelta)

        let newLhsNum: Int64
        let newRhsNum: Int64
        if context.lhsMovesUpward {
            let (lhsCandidate, lhsOverflow) = context.lhsNumerator.addingReportingOverflow(signedDelta)
            let (rhsCandidate, rhsOverflow) = context.rhsNumerator.subtractingReportingOverflow(signedDelta)
            guard lhsOverflow == false, rhsOverflow == false else { return nil }
            newLhsNum = lhsCandidate
            newRhsNum = rhsCandidate
        } else {
            let (lhsCandidate, lhsOverflow) = context.lhsNumerator.subtractingReportingOverflow(signedDelta)
            let (rhsCandidate, rhsOverflow) = context.rhsNumerator.addingReportingOverflow(signedDelta)
            guard lhsOverflow == false, rhsOverflow == false else { return nil }
            newLhsNum = lhsCandidate
            newRhsNum = rhsCandidate
        }

        guard let newChoice1 = choiceFromNumerator(newLhsNum, denominator: context.denominator, original: lhs),
              let newChoice2 = choiceFromNumerator(newRhsNum, denominator: context.denominator, original: rhs)
        else { return nil }

        return (newChoice1, newChoice2)
    }

    // MARK: - Float context construction

    /// Builds a float redistribution context for same-tag float pairs.
    ///
    /// Converts both values and the lhs target to rational form with a common denominator,
    /// enabling integer-step redistribution in the numerator space.
    private func makeFloatRedistributionContext(
        lhs: ChoiceValue,
        rhs: ChoiceValue,
        lhsTargetBitPattern: UInt64
    ) -> FloatRedistributionContext? {
        let tag = lhs.tag
        guard tag == rhs.tag, tag == .double || tag == .float else { return nil }
        guard case let .floating(lhsValue, _, _) = lhs,
              case let .floating(rhsValue, _, _) = rhs,
              lhsValue.isFinite,
              rhsValue.isFinite
        else { return nil }

        let targetChoice = ChoiceValue(
            tag.makeConvertible(bitPattern64: lhsTargetBitPattern),
            tag: tag
        )
        guard case let .floating(targetValue, _, _) = targetChoice,
              targetValue.isFinite
        else { return nil }

        guard let lhsRatio = FloatShrink.integerRatio(for: lhsValue, tag: tag),
              let rhsRatio = FloatShrink.integerRatio(for: rhsValue, tag: tag),
              let targetRatio = FloatShrink.integerRatio(for: targetValue, tag: tag),
              let lhsAndRhsDenominator = leastCommonMultiple(lhsRatio.denominator, rhsRatio.denominator),
              let denominator = leastCommonMultiple(lhsAndRhsDenominator, targetRatio.denominator),
              denominator > 0
        else { return nil }

        guard let lhsNumerator = scaledNumerator(lhsRatio, to: denominator),
              let rhsNumerator = scaledNumerator(rhsRatio, to: denominator),
              let targetNumerator = scaledNumerator(targetRatio, to: denominator)
        else { return nil }

        let lhsMovesUpward = targetNumerator > lhsNumerator
        let rawDistance = absDiff(lhsNumerator, targetNumerator)
        guard rawDistance > 0 else { return nil }

        return FloatRedistributionContext(
            lhsNumerator: lhsNumerator,
            rhsNumerator: rhsNumerator,
            denominator: denominator,
            lhsMovesUpward: lhsMovesUpward,
            distance: rawDistance
        )
    }

    // MARK: - Mixed context construction

    /// Builds a mixed redistribution context for cross-type (float+integer) pairs.
    ///
    /// At least one side must be floating-point. The step size equals the common denominator
    /// when one side is integer, ensuring integer values remain integral after redistribution.
    private func makeMixedRedistributionContext(
        lhs: ChoiceValue,
        rhs: ChoiceValue,
        lhsTargetBitPattern: UInt64
    ) -> MixedRedistributionContext? {
        // Only applies to cross-tag pairs where at least one is floating-point.
        guard lhs.tag != rhs.tag else { return nil }
        let lhsIsFloat = lhs.tag == .double || lhs.tag == .float
        let rhsIsFloat = rhs.tag == .double || rhs.tag == .float
        guard lhsIsFloat || rhsIsFloat else { return nil }

        guard let lhsRatio = rationalForChoice(lhs),
              let rhsRatio = rationalForChoice(rhs),
              let targetRatio = rationalForTarget(lhs, targetBitPattern: lhsTargetBitPattern),
              let lhsAndRhsDenominator = leastCommonMultiple(lhsRatio.denominator, rhsRatio.denominator),
              let denominator = leastCommonMultiple(lhsAndRhsDenominator, targetRatio.denominator),
              denominator > 0
        else { return nil }

        guard let lhsNumerator = scaledNumerator(lhsRatio, to: denominator),
              let rhsNumerator = scaledNumerator(rhsRatio, to: denominator),
              let targetNumerator = scaledNumerator(targetRatio, to: denominator)
        else { return nil }

        let lhsIsInteger = isIntegerTag(lhs.tag)
        let rhsIsInteger = isIntegerTag(rhs.tag)
        let intStepSize: UInt64 = (lhsIsInteger || rhsIsInteger) ? denominator : 1

        guard intStepSize > 0 else { return nil }

        let lhsMovesUpward = targetNumerator > lhsNumerator
        let rawDistance = absDiff(lhsNumerator, targetNumerator)
        guard rawDistance > 0 else { return nil }

        let distanceInSteps = rawDistance / intStepSize
        guard distanceInSteps > 0 else { return nil }

        return MixedRedistributionContext(
            lhsNumerator: lhsNumerator,
            rhsNumerator: rhsNumerator,
            denominator: denominator,
            intStepSize: intStepSize,
            lhsMovesUpward: lhsMovesUpward,
            distanceInSteps: distanceInSteps
        )
    }

    // MARK: - Rational arithmetic helpers

    private func rationalForChoice(
        _ choice: ChoiceValue
    ) -> (numerator: Int64, denominator: UInt64)? {
        switch choice {
        case let .floating(value, _, tag):
            guard value.isFinite else { return nil }
            return FloatShrink.integerRatio(for: value, tag: tag)
        case let .signed(value, _, _):
            return (value, 1)
        case let .unsigned(value, _):
            guard value <= UInt64(Int64.max) else { return nil }
            return (Int64(value), 1)
        }
    }

    private func rationalForTarget(
        _ choice: ChoiceValue,
        targetBitPattern: UInt64
    ) -> (numerator: Int64, denominator: UInt64)? {
        switch choice {
        case let .floating(_, _, tag):
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            guard case let .floating(targetValue, _, _) = targetChoice,
                  targetValue.isFinite
            else { return nil }
            return FloatShrink.integerRatio(for: targetValue, tag: tag)
        case let .signed(_, _, tag):
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            guard case let .signed(targetValue, _, _) = targetChoice else { return nil }
            return (targetValue, 1)
        case let .unsigned(_, tag):
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            guard case let .unsigned(targetValue, _) = targetChoice else { return nil }
            guard targetValue <= UInt64(Int64.max) else { return nil }
            return (Int64(targetValue), 1)
        }
    }

    private func choiceFromNumerator(
        _ numerator: Int64,
        denominator: UInt64,
        original: ChoiceValue
    ) -> ChoiceValue? {
        switch original {
        case let .floating(_, _, tag):
            let value = Double(numerator) / Double(denominator)
            return floatingChoice(from: value, tag: tag)
        case let .signed(_, _, tag):
            let denom = Int64(denominator)
            guard denom > 0, numerator % denom == 0 else { return nil }
            let intValue = numerator / denom
            let narrowed = ChoiceValue(intValue, tag: tag)
            guard case let .signed(narrowedValue, _, _) = narrowed,
                  narrowedValue == intValue
            else { return nil }
            return narrowed
        case let .unsigned(_, tag):
            let denom = Int64(denominator)
            guard denom > 0, numerator % denom == 0 else { return nil }
            let intValue = numerator / denom
            guard intValue >= 0 else { return nil }
            let uintValue = UInt64(intValue)
            let narrowed = ChoiceValue(uintValue, tag: tag)
            guard case let .unsigned(narrowedValue, _) = narrowed,
                  narrowedValue == uintValue
            else { return nil }
            return narrowed
        }
    }

    private func scaledNumerator(
        _ ratio: (numerator: Int64, denominator: UInt64),
        to denominator: UInt64
    ) -> Int64? {
        guard denominator % ratio.denominator == 0 else { return nil }
        let scale = denominator / ratio.denominator
        guard scale <= UInt64(Int64.max) else { return nil }
        let (scaled, overflow) = ratio.numerator.multipliedReportingOverflow(by: Int64(scale))
        guard overflow == false else { return nil }
        return scaled
    }

    private func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }

    private func leastCommonMultiple(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard lhs > 0, rhs > 0 else { return nil }
        let gcd = greatestCommonDivisor(lhs, rhs)
        let reducedLHS = lhs / gcd
        let (product, overflow) = reducedLHS.multipliedReportingOverflow(by: rhs)
        guard overflow == false else { return nil }
        return product
    }

    private func floatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
        switch tag {
        case .double:
            guard value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        default:
            return nil
        }
    }

    private func isIntegerTag(_ tag: TypeTag) -> Bool {
        switch tag {
        case .int, .int8, .int16, .int32, .int64,
             .uint, .uint8, .uint16, .uint32, .uint64:
            true
        default:
            false
        }
    }

    // MARK: - Pair key helpers

    /// Returns a sorted pair of complexity keys for two `ChoiceValue`s.
    ///
    /// Same-tag pairs use the native `shortlexKey`. Cross-type pairs map both values
    /// onto the `FloatShortlex` scale via their absolute `Double` magnitude.
    private func sortedPairKeys(
        _ a: ChoiceValue,
        _ b: ChoiceValue
    ) -> [UInt64] {
        if a.tag == b.tag {
            return [a.shortlexKey, b.shortlexKey].sorted()
        }
        return [crossTypeKey(a), crossTypeKey(b)].sorted()
    }

    private func crossTypeKey(_ choice: ChoiceValue) -> UInt64 {
        switch choice {
        case let .floating(value, _, _):
            FloatShortlex.shortlexKey(for: value)
        case let .signed(value, _, _):
            FloatShortlex.shortlexKey(for: Double(value))
        case let .unsigned(value, _):
            FloatShortlex.shortlexKey(for: Double(value))
        }
    }

    // MARK: - Distance helpers

    private func absDiff(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
    }

    private func absDiff(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        if lhs >= rhs {
            return UInt64(lhs &- rhs)
        }
        return UInt64(rhs &- lhs)
    }
}
