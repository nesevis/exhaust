//
//  BindAwareRedistributeEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Bind-aware cross-region value redistribution encoder.
///
/// For generators with bind-dependent ranges (e.g. `bind(0...50, { n in 0...max(1,n) })`),
/// the standard ``CrossStageRedistributeEncoder`` fails because it operates on positions
/// independently — changing an inner value changes the valid range for its bound values,
/// but the encoder doesn't account for this causal link.
///
/// This encoder identifies bind regions via ``BindSpanIndex``, pairs them by depth,
/// and redistributes mass between their inner values. Bound values are handled by
/// ``GuidedMaterializer`` with per-region maximization: the sink region's bound values
/// are maximized to absorb freed mass, while the source region's bounds clamp naturally.
///
/// All numeric types (integers and floats) are handled uniformly via rational arithmetic:
/// integer values have denominator 1, floats are decomposed via ``FloatShrink.integerRatio``.
/// Mixed pairs (float + integer) use a step size equal to the common denominator to preserve
/// integrality on the integer side.
///
/// Uses ``FindIntegerStepper`` for feedback-driven delta search, with a non-monotonic
/// fallback phase when the monotone search converges without finding an improvement.
public struct BindAwareRedistributeEncoder: AdaptiveEncoder {
    public init() {}

    public let name = "bindAwareRedistribute"
    public let phase = ReductionPhase.redistribution

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .bounded, maxMaterializations: 0)
    }

    public func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        guard let bindIndex, bindIndex.regions.count >= 2 else { return nil }
        let r = bindIndex.regions.count
        return min(r * r, 32) * 14
    }

    // MARK: - Types

    /// A bind region with its extracted inner numeric value.
    struct RegionProfile {
        let regionIndex: Int
        let region: BindSpanIndex.BindRegion
        let innerIndex: Int
        let innerValue: ChoiceSequenceValue.Value
    }

    /// A redistribution plan: source loses mass, sink gains mass.
    ///
    /// All arithmetic operates in a shared numerator space with ``commonDenominator``.
    /// The ``stepSize`` is 1 for same-type pairs and equals the common denominator for
    /// mixed (float + integer) pairs, ensuring integer sides receive whole-number deltas.
    struct RegionPairPlan {
        let source: RegionProfile
        let sink: RegionProfile
        let sourceNumerator: Int64
        let sinkNumerator: Int64
        let sourceTargetNumerator: Int64
        let commonDenominator: UInt64
        let stepSize: UInt64
        let maxDelta: UInt64
        let sourceMovesUpward: Bool

        /// The bound range of the sink region (for maximization).
        var sinkBoundRange: ClosedRange<Int> { sink.region.boundRange }
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var plans: [RegionPairPlan] = []
    private var planIndex = 0
    private var stepper = FindIntegerStepper()
    private var needsFirstProbe = true
    private var stepperConverged = false

    // Fallback state
    private var inFallbackPhase = false
    private var fallbackDeltas: [UInt64] = []
    private var fallbackIndex = 0

    // MARK: - Plan Construction

    /// Builds redistribution plans from a sequence and bind index.
    static func buildPlans(
        from sequence: ChoiceSequence,
        bindIndex: BindSpanIndex
    ) -> [RegionPairPlan] {
        var profiles = [RegionProfile]()

        for (regionIndex, region) in bindIndex.regions.enumerated() {
            // Find the first numeric value entry in the inner range.
            var innerIndex: Int?
            var innerValue: ChoiceSequenceValue.Value?
            var idx = region.innerRange.lowerBound
            // while-loop: avoiding IteratorProtocol overhead in debug builds
            while idx <= region.innerRange.upperBound {
                let entry = sequence[idx]
                switch entry {
                case let .value(v), let .reduced(v):
                    switch v.choice {
                    case .unsigned, .signed, .floating:
                        innerIndex = idx
                        innerValue = v
                    }
                default:
                    break
                }
                if innerIndex != nil { break }
                idx += 1
            }

            guard let innerIdx = innerIndex, let innerVal = innerValue else { continue }

            profiles.append(RegionProfile(
                regionIndex: regionIndex,
                region: region,
                innerIndex: innerIdx,
                innerValue: innerVal
            ))
        }

        // Build plans: pair regions at the same bind depth.
        var plans = [RegionPairPlan]()
        var pi = 0
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while pi < profiles.count {
            var pj = 0
            while pj < profiles.count {
                if pi != pj {
                    let source = profiles[pi]
                    let sink = profiles[pj]
                    // Only pair at same bind depth.
                    let sourceDepth = bindIndex.bindDepth(at: source.region.innerRange.lowerBound)
                    let sinkDepth = bindIndex.bindDepth(at: sink.region.innerRange.lowerBound)
                    guard sourceDepth == sinkDepth else {
                        pj += 1
                        continue
                    }
                    if let plan = makePlan(source: source, sink: sink) {
                        plans.append(plan)
                    }
                }
                pj += 1
            }
            pi += 1
        }

        // Guard against quadratic blowup.
        if plans.count > 32 {
            return Array(plans.prefix(32))
        }
        return plans
    }

    /// Builds a redistribution plan for a (source, sink) pair using rational arithmetic.
    private static func makePlan(source: RegionProfile, sink: RegionProfile) -> RegionPairPlan? {
        let sourceChoice = source.innerValue.choice
        let sinkChoice = sink.innerValue.choice

        guard let sourceRatio = rationalForChoice(sourceChoice),
              let sinkRatio = rationalForChoice(sinkChoice)
        else { return nil }

        let sourceTargetBP = sourceChoice.reductionTarget(
            in: source.innerValue.isRangeExplicit ? source.innerValue.validRange : nil
        )
        guard let targetRatio = rationalForTarget(sourceChoice, targetBitPattern: sourceTargetBP)
        else { return nil }

        // Compute common denominator across source, sink, and target.
        guard let srcAndSinkDenom = leastCommonMultiple(sourceRatio.denominator, sinkRatio.denominator),
              let commonDenominator = leastCommonMultiple(srcAndSinkDenom, targetRatio.denominator),
              commonDenominator > 0
        else { return nil }

        guard let sourceNumerator = scaledNumerator(sourceRatio, to: commonDenominator),
              let sinkNumerator = scaledNumerator(sinkRatio, to: commonDenominator),
              let targetNumerator = scaledNumerator(targetRatio, to: commonDenominator)
        else { return nil }

        // Step size: for mixed pairs (one integer, one float), the integer side
        // must receive whole-number deltas, so the step equals the common denominator.
        let sourceIsInteger = isIntegerTag(sourceChoice.tag)
        let sinkIsInteger = isIntegerTag(sinkChoice.tag)
        let isMixed = sourceIsInteger != sinkIsInteger
        let stepSize: UInt64 = isMixed ? commonDenominator : 1
        guard stepSize > 0 else { return nil }

        let sourceMovesUpward = targetNumerator > sourceNumerator
        let rawDistance = absDiff(sourceNumerator, targetNumerator)
        guard rawDistance > 0 else { return nil }

        let maxDelta = rawDistance / stepSize
        guard maxDelta > 0 else { return nil }

        // Sink must have room to absorb.
        if let range = sink.innerValue.validRange {
            let sinkBP = sinkChoice.bitPattern64
            guard sinkBP < range.upperBound else { return nil }
        }

        return RegionPairPlan(
            source: source,
            sink: sink,
            sourceNumerator: sourceNumerator,
            sinkNumerator: sinkNumerator,
            sourceTargetNumerator: targetNumerator,
            commonDenominator: commonDenominator,
            stepSize: stepSize,
            maxDelta: maxDelta,
            sourceMovesUpward: sourceMovesUpward
        )
    }

    // MARK: - Per-Plan Initialization

    /// Initializes the encoder for a specific plan.
    mutating func startPlan(sequence: ChoiceSequence, plan: RegionPairPlan) {
        self.sequence = sequence
        self.plans = [plan]
        self.planIndex = 0
        self.stepper = FindIntegerStepper()
        self.needsFirstProbe = true
        self.stepperConverged = false
        self.inFallbackPhase = false
        self.fallbackDeltas = []
        self.fallbackIndex = 0
    }

    // MARK: - AdaptiveEncoder Conformance

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        self.sequence = sequence
        self.planIndex = 0
        self.stepper = FindIntegerStepper()
        self.needsFirstProbe = true
        self.stepperConverged = false
        self.inFallbackPhase = false
        self.fallbackDeltas = []
        self.fallbackIndex = 0
        // Plans are built externally by the scheduler.
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while planIndex < plans.count {
            if let candidate = advanceCurrentPlan(lastAccepted: lastAccepted) {
                return candidate
            }
            // Current plan exhausted (monotone + fallback).
            planIndex += 1
            needsFirstProbe = true
            stepperConverged = false
            inFallbackPhase = false
            fallbackDeltas = []
            fallbackIndex = 0
        }
        return nil
    }

    // MARK: - Per-plan advancement

    private mutating func advanceCurrentPlan(lastAccepted: Bool) -> ChoiceSequence? {
        if inFallbackPhase {
            return advanceFallback(lastAccepted: lastAccepted)
        }
        if stepperConverged {
            // Monotone phase done — enter fallback.
            inFallbackPhase = true
            buildFallbackDeltas()
            return advanceFallback(lastAccepted: false)
        }
        return advanceMonotone(lastAccepted: lastAccepted)
    }

    // MARK: - Monotone phase

    private mutating func advanceMonotone(lastAccepted: Bool) -> ChoiceSequence? {
        let plan = plans[planIndex]

        let k: Int
        if needsFirstProbe {
            needsFirstProbe = false
            k = stepper.start()
        } else {
            guard let next = stepper.advance(lastAccepted: lastAccepted) else {
                stepperConverged = true
                return nil
            }
            k = next
        }

        let delta = UInt64(k)
        guard delta > 0, delta <= plan.maxDelta else {
            if delta == 0 {
                return advanceMonotone(lastAccepted: true)
            }
            return advanceMonotone(lastAccepted: false)
        }

        return buildCandidate(plan: plan, delta: delta)
    }

    // MARK: - Fallback phase

    private mutating func buildFallbackDeltas() {
        let plan = plans[planIndex]
        let distance = plan.maxDelta

        var deltas = [distance]
        if distance > 1 { deltas.append(distance - 1) }
        deltas.append(max(1, distance / 2))
        deltas.append(max(1, distance / 4))

        // Deduplicate and sort descending.
        let unique = Array(Set(deltas))
            .filter { $0 > 0 && $0 <= distance }
            .sorted(by: >)

        fallbackDeltas = unique
        fallbackIndex = 0
    }

    private mutating func advanceFallback(lastAccepted: Bool) -> ChoiceSequence? {
        let plan = plans[planIndex]

        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while fallbackIndex < fallbackDeltas.count {
            let delta = fallbackDeltas[fallbackIndex]
            fallbackIndex += 1

            if let candidate = buildCandidate(plan: plan, delta: delta) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Candidate construction

    private func buildCandidate(plan: RegionPairPlan, delta: UInt64) -> ChoiceSequence? {
        // Scale delta to numerator space.
        let (actualDelta, stepOverflow) = delta.multipliedReportingOverflow(by: plan.stepSize)
        guard stepOverflow == false, actualDelta <= UInt64(Int64.max) else { return nil }
        let signedDelta = Int64(actualDelta)

        // Source: move by delta toward target.
        // Sink: move by delta away from target (compensating).
        let newSourceNum: Int64
        let newSinkNum: Int64
        if plan.sourceMovesUpward {
            let (srcCandidate, srcOverflow) = plan.sourceNumerator.addingReportingOverflow(signedDelta)
            let (sinkCandidate, sinkOverflow) = plan.sinkNumerator.subtractingReportingOverflow(signedDelta)
            guard srcOverflow == false, sinkOverflow == false else { return nil }
            newSourceNum = srcCandidate
            newSinkNum = sinkCandidate
        } else {
            let (srcCandidate, srcOverflow) = plan.sourceNumerator.subtractingReportingOverflow(signedDelta)
            let (sinkCandidate, sinkOverflow) = plan.sinkNumerator.addingReportingOverflow(signedDelta)
            guard srcOverflow == false, sinkOverflow == false else { return nil }
            newSourceNum = srcCandidate
            newSinkNum = sinkCandidate
        }

        // Convert back to ChoiceValues.
        guard let newSourceChoice = Self.choiceFromNumerator(
            newSourceNum, denominator: plan.commonDenominator, original: plan.source.innerValue.choice
        ) else { return nil }
        guard let newSinkChoice = Self.choiceFromNumerator(
            newSinkNum, denominator: plan.commonDenominator, original: plan.sink.innerValue.choice
        ) else { return nil }

        // Validate range constraints.
        if plan.source.innerValue.isRangeExplicit,
           newSourceChoice.fits(in: plan.source.innerValue.validRange) == false {
            return nil
        }
        if plan.sink.innerValue.isRangeExplicit,
           newSinkChoice.fits(in: plan.sink.innerValue.validRange) == false {
            return nil
        }

        let sourceEntry = ChoiceSequenceValue.reduced(.init(
            choice: newSourceChoice,
            validRange: plan.source.innerValue.validRange,
            isRangeExplicit: plan.source.innerValue.isRangeExplicit
        ))
        let sinkEntry = ChoiceSequenceValue.value(.init(
            choice: newSinkChoice,
            validRange: plan.sink.innerValue.validRange,
            isRangeExplicit: plan.sink.innerValue.isRangeExplicit
        ))

        var candidate = sequence
        candidate[plan.source.innerIndex] = sourceEntry
        candidate[plan.sink.innerIndex] = sinkEntry

        // Improvement check: candidate must shortlex-precede the original.
        guard candidate.shortLexPrecedes(sequence) else { return nil }

        return candidate
    }

    // MARK: - Rational arithmetic helpers

    static func rationalForChoice(
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

    static func rationalForTarget(
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

    static func choiceFromNumerator(
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

    static func floatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
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

    static func isIntegerTag(_ tag: TypeTag) -> Bool {
        switch tag {
        case .int, .int8, .int16, .int32, .int64,
             .uint, .uint8, .uint16, .uint32, .uint64:
            true
        default:
            false
        }
    }

    static func scaledNumerator(
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

    static func leastCommonMultiple(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard lhs > 0, rhs > 0 else { return nil }
        let gcd = greatestCommonDivisor(lhs, rhs)
        let reducedLHS = lhs / gcd
        let (product, overflow) = reducedLHS.multipliedReportingOverflow(by: rhs)
        guard overflow == false else { return nil }
        return product
    }

    static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
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

    static func absDiff(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        if lhs >= rhs {
            return UInt64(bitPattern: lhs &- rhs)
        }
        return UInt64(bitPattern: rhs &- lhs)
    }
}
