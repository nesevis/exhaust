//
//  GraphExchangeEncoder.swift
//  Exhaust
//

// MARK: - Graph Exchange Encoder

/// Moves magnitude between leaves to enable future structural operations.
///
/// Operates in two modes based on the ``ExchangeScope``:
/// - **Redistribution**: for each source-receiver pair, binary-searches on delta magnitude via ``MaxBinarySearchStepper`` to find the largest accepted transfer. The graph determines which pairs; the encoder determines how much.
/// - **Tandem**: lockstep reduction of same-typed sibling values. Stub — full implementation deferred.
///
/// This is a value encoder: the delta magnitude is above the opacity boundary and requires predicate feedback to find.
struct GraphExchangeEncoder: GraphEncoder {
    let name: EncoderName = .graphRedistribution

    // MARK: - State

    private var mode: Mode = .idle
    private var sequence: ChoiceSequence = ChoiceSequence()

    private enum Mode {
        case idle
        case redistribution(RedistributionState)
        case lockstep(LockstepState)
    }

    /// A single window plan for lockstep reduction.
    ///
    /// Each plan is a suffix of an index set with the same ``TypeTag``. Suffix windows let the encoder skip a near-target leader that would otherwise block the whole set.
    private struct LockstepWindowPlan {
        let windowIndices: [Int]
        let tag: TypeTag
        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)]
        let searchUpward: Bool
        let distance: UInt64
        let usesFloatingSteps: Bool
    }

    private enum LockstepProbePhase {
        case directShot
        case binarySearchStart
        case binarySearch
    }

    private struct LockstepState {
        var plans: [LockstepWindowPlan]
        var planIndex: Int
        var probePhase: LockstepProbePhase
        var stepper: MaxBinarySearchStepper
        var lastEmittedCandidate: ChoiceSequence?
        /// Whether the last emitted candidate was a direct shot (skip binary search on acceptance).
        var lastWasDirectShot: Bool
    }

    /// Rational-arithmetic context for cross-type or float redistribution.
    ///
    /// Both sides are represented as numerators over a common denominator. ``intStepSize`` is `denominator` when at least one side is an integer (forcing integer-step deltas), otherwise 1.
    struct MixedRedistributionContext {
        let sourceNumerator: Int64
        let sinkNumerator: Int64
        let denominator: UInt64
        let intStepSize: UInt64
        let sourceMovesUpward: Bool
        let distanceInSteps: UInt64
    }

    private struct RedistributionState {
        let pairs: [(sourceIndex: Int, sinkIndex: Int, sourceTag: TypeTag, sinkTag: TypeTag, maxDelta: UInt64, mixedContext: MixedRedistributionContext?)]
        var pairIndex: Int
        var stepper: MaxBinarySearchStepper?
        var didEmitCandidate: Bool
        var lastEmittedCandidate: ChoiceSequence?
        /// Whether the full-delta probe has been tried for the current pair.
        var triedFullDelta: Bool
        /// Pair indices that had at least one accepted probe this pass. Only these are re-evaluated on the next pass.
        var acceptedPairIndices: Set<Int>
        /// Number of completed passes (capped at ``maxPasses`` to bound work).
        var passCount: Int
        /// Which pair indices to evaluate on the current pass. Nil means all pairs.
        var activePairIndices: Set<Int>?
    }

    /// Maximum number of redistribution passes before the encoder stops re-evaluating pairs. With targeted re-evaluation (only accepted pairs), subsequent passes are cheap — O(log maxDelta) probes per accepted pair.
    private static let maxPasses = 16

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        sequence = scope.baseSequence
        mode = .idle

        guard case let .exchange(exchangeScope) = scope.transformation.operation else {
            return
        }

        let graph = scope.graph

        switch exchangeScope {
        case let .redistribution(redistScope):
            startRedistribution(scope: redistScope, graph: graph)
        case let .tandem(tandemScope):
            startLockstep(scope: tandemScope, graph: graph)
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        switch mode {
        case .idle:
            return nil
        case var .redistribution(state):
            // Update baseline on acceptance.
            if lastAccepted, let accepted = state.lastEmittedCandidate {
                sequence = accepted
                state.acceptedPairIndices.insert(state.pairIndex)
            }
            state.lastEmittedCandidate = nil
            let result = nextRedistributionProbe(state: &state, lastAccepted: lastAccepted)
            mode = .redistribution(state)
            return result
        case var .lockstep(state):
            if lastAccepted, let accepted = state.lastEmittedCandidate {
                sequence = accepted
            }
            state.lastEmittedCandidate = nil
            let result = nextLockstepProbe(state: &state, lastAccepted: lastAccepted)
            mode = .lockstep(state)
            return result
        }
    }

    // MARK: - Redistribution

    private mutating func startRedistribution(
        scope: RedistributionScope,
        graph: ChoiceGraph
    ) {
        var pairs: [(sourceIndex: Int, sinkIndex: Int, sourceTag: TypeTag, sinkTag: TypeTag, maxDelta: UInt64, mixedContext: MixedRedistributionContext?)] = []

        for pair in scope.pairs {
            guard let sourceRange = graph.nodes[pair.sourceNodeID].positionRange,
                  let sinkRange = graph.nodes[pair.sinkNodeID].positionRange else {
                continue
            }
            guard case let .chooseBits(sourceMetadata) = graph.nodes[pair.sourceNodeID].kind,
                  case let .chooseBits(sinkMetadata) = graph.nodes[pair.sinkNodeID].kind else {
                continue
            }

            let needsMixedMath = sourceMetadata.typeTag != sinkMetadata.typeTag
                || sourceMetadata.typeTag.isFloatingPoint
                || sinkMetadata.typeTag.isFloatingPoint

            if needsMixedMath {
                // Build a rational-arithmetic context. Handles same-tag float
                // pairs and any cross-type combination.
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
            let maxDelta: UInt64
            if sourceMetadata.value.bitPattern64 > sourceTarget {
                maxDelta = sourceMetadata.value.bitPattern64 - sourceTarget
            } else {
                maxDelta = sourceTarget - sourceMetadata.value.bitPattern64
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

        mode = .redistribution(RedistributionState(
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

    private func nextRedistributionProbe(
        state: inout RedistributionState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.pairIndex < state.pairs.count {
            // Skip pairs not in the active set (on subsequent passes,
            // only re-evaluate pairs that had accepted probes).
            if let active = state.activePairIndices,
               active.contains(state.pairIndex) == false
            {
                state.pairIndex += 1
                continue
            }

            let pair = state.pairs[state.pairIndex]

            if state.stepper == nil {
                // Recompute maxDelta from the CURRENT sequence — prior pair
                // acceptances may have changed the source's value.
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

        // All pairs exhausted. If any were accepted this pass and we
        // haven't hit the pass cap, reset for another pass — but only
        // re-evaluate the pairs that made progress. This avoids wasting
        // O(pairs × log(maxDelta)) probes on pairs that can't redistribute.
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
    private func currentMaxDelta(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        sinkTag: TypeTag,
        usesMixed: Bool
    ) -> (maxDelta: UInt64, mixedContext: MixedRedistributionContext?) {
        guard let sourceValue = sequence[sourceIndex].value else { return (0, nil) }

        if usesMixed {
            guard let sinkValue = sequence[sinkIndex].value else { return (0, nil) }
            guard let context = Self.makeMixedRedistributionContext(
                sourceChoice: sourceValue.choice,
                sinkChoice: sinkValue.choice,
                sourceValidRange: sourceValue.validRange,
                sourceIsRangeExplicit: sourceValue.isRangeExplicit
            ) else { return (0, nil) }
            return (context.distanceInSteps, context)
        }

        // Same-tag integer: bit-pattern distance.
        let sourceBP = sourceValue.choice.bitPattern64
        let targetBP = sourceValue.choice.reductionTarget(in: sourceValue.validRange)
        let distance = sourceBP > targetBP ? sourceBP - targetBP : targetBP - sourceBP
        return (distance, nil)
    }

    /// Builds a redistribution candidate by transferring `delta` units from source to sink.
    ///
    /// For pairs with a ``MixedRedistributionContext`` (cross-type or floating-point), uses rational arithmetic with a common denominator. For same-tag integer pairs, operates in semantic Int64 value space.
    private func buildRedistributionCandidate(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        sinkTag: TypeTag,
        delta: UInt64,
        mixedContext: MixedRedistributionContext?
    ) -> ChoiceSequence? {
        guard delta > 0 else { return nil }

        let sourceEntry = sequence[sourceIndex]
        let sinkEntry = sequence[sinkIndex]
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

            var candidate = sequence
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
        // When both sides' declared domain equals the natural type width, we
        // use bit-pattern modular arithmetic with a width-aware mask. This
        // matches the wrapping arithmetic (`&+`/`&-`) the property under test
        // likely uses for the same type and lets redistribution reach
        // boundary counterexamples like `(Int16.min, -1)` that semantic-space
        // arithmetic would reject as overflow. See
        // `bound5-redistribution-wraparound-diagnosis.md` for the motivating
        // trace.
        //
        // When either side carries an explicit narrow range, we retain
        // semantic Int64 arithmetic with `bitPattern(fromSemantic:tag:)`
        // rejecting out-of-range results — the encoder must honor the user's
        // declared domain, not the type's natural width.
        let canWrapModulo = sourceValue.allowsModularArithmetic
            && sinkValue.allowsModularArithmetic

        if canWrapModulo {
            let mask = sourceTag.bitPatternRange.upperBound
            let sourceBP = sourceValue.choice.bitPattern64
            let sinkBP = sinkValue.choice.bitPattern64
            let targetBP = sourceValue.choice.reductionTarget(in: sourceValue.validRange)

            let newSourceBP: UInt64
            let newSinkBP: UInt64
            if sourceBP > targetBP {
                newSourceBP = (sourceBP &- delta) & mask
                newSinkBP = (sinkBP &+ delta) & mask
            } else {
                newSourceBP = (sourceBP &+ delta) & mask
                newSinkBP = (sinkBP &- delta) & mask
            }

            var candidate = sequence
            candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBP)
            candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBP)
            return candidate
        }

        // Narrow-range fallback: semantic Int64 arithmetic.
        guard delta <= UInt64(Int64.max) else { return nil }

        let sourceSemanticValue = Self.semanticValue(sourceValue.choice)
        let sinkSemanticValue = Self.semanticValue(sinkValue.choice)
        let targetSemanticValue = Self.semanticValue(
            ChoiceValue(
                sourceTag.makeConvertible(
                    bitPattern64: sourceValue.choice.reductionTarget(in: sourceValue.validRange)
                ),
                tag: sourceTag
            )
        )

        let signedDelta = Int64(delta)
        let newSourceSemantic: Int64
        let newSinkSemantic: Int64

        if sourceSemanticValue > targetSemanticValue {
            let (candidateSource, sourceOverflow) = sourceSemanticValue.subtractingReportingOverflow(signedDelta)
            let (candidateSink, sinkOverflow) = sinkSemanticValue.addingReportingOverflow(signedDelta)
            guard sourceOverflow == false, sinkOverflow == false else { return nil }
            newSourceSemantic = candidateSource
            newSinkSemantic = candidateSink
        } else {
            let (candidateSource, sourceOverflow) = sourceSemanticValue.addingReportingOverflow(signedDelta)
            let (candidateSink, sinkOverflow) = sinkSemanticValue.subtractingReportingOverflow(signedDelta)
            guard sourceOverflow == false, sinkOverflow == false else { return nil }
            newSourceSemantic = candidateSource
            newSinkSemantic = candidateSink
        }

        guard let newSourceBP = Self.bitPattern(fromSemantic: newSourceSemantic, tag: sourceTag),
              let newSinkBP = Self.bitPattern(fromSemantic: newSinkSemantic, tag: sinkValue.choice.tag) else {
            return nil
        }

        var candidate = sequence
        candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBP)
        candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBP)

        return candidate
    }

    /// Extracts the semantic value as Int64 from a ChoiceValue.
    private static func semanticValue(_ choice: ChoiceValue) -> Int64 {
        switch choice {
        case let .unsigned(value, _):
            return Int64(clamping: value)
        case let .signed(value, _, _):
            return value
        case let .floating(value, _, _):
            return Int64(value)
        }
    }

    /// Converts a semantic Int64 value to the type's ``BitPatternConvertible/bitPattern64`` encoding. Returns nil if out of range.
    private static func bitPattern(fromSemantic value: Int64, tag: TypeTag) -> UInt64? {
        switch tag {
        case .uint8:
            guard value >= 0, value <= Int64(UInt8.max) else { return nil }
            return UInt8(value).bitPattern64
        case .int8:
            guard value >= Int64(Int8.min), value <= Int64(Int8.max) else { return nil }
            return Int8(value).bitPattern64
        case .uint16:
            guard value >= 0, value <= Int64(UInt16.max) else { return nil }
            return UInt16(value).bitPattern64
        case .int16:
            guard value >= Int64(Int16.min), value <= Int64(Int16.max) else { return nil }
            return Int16(value).bitPattern64
        case .uint32:
            guard value >= 0, value <= Int64(UInt32.max) else { return nil }
            return UInt32(value).bitPattern64
        case .int32:
            guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { return nil }
            return Int32(value).bitPattern64
        case .uint, .uint64:
            guard value >= 0 else { return nil }
            return UInt64(value).bitPattern64
        case .int:
            return Int(value).bitPattern64
        case .int64:
            return value.bitPattern64
        case .bits:
            guard value >= 0 else { return nil }
            return UInt64(value).bitPattern64
        case .double, .float, .float16, .date:
            return nil
        }
    }

    // MARK: - Lockstep Reduction

    /// Builds suffix-window plans from each tandem group and dispatches the lockstep state.
    ///
    /// For each group of same-tag leaves, generates plans that drop progressively more leading entries — this prevents a near-target leader from blocking the whole set.
    private mutating func startLockstep(scope: TandemScope, graph: ChoiceGraph) {
        var plans: [LockstepWindowPlan] = []

        for group in scope.groups {
            // Resolve leaf node IDs to sorted sequence indices.
            var indices: [Int] = []
            for nodeID in group.leafNodeIDs {
                guard let range = graph.nodes[nodeID].positionRange else { continue }
                indices.append(range.lowerBound)
            }
            indices.sort()
            guard indices.count >= 2 else { continue }

            // Build suffix windows: drop leading entries one at a time.
            var offset = 0
            while offset < indices.count - 1 {
                let windowIndices = Array(indices[offset...])
                if let plan = makeLockstepWindowPlan(windowIndices: windowIndices) {
                    plans.append(plan)
                }
                offset += 1
            }
        }

        guard plans.isEmpty == false else { return }

        mode = .lockstep(LockstepState(
            plans: plans,
            planIndex: 0,
            probePhase: .directShot,
            stepper: MaxBinarySearchStepper(lo: 0, hi: 0),
            lastEmittedCandidate: nil,
            lastWasDirectShot: false
        ))
    }

    /// Constructs a window plan from indices, computing direction and distance from the leader.
    private func makeLockstepWindowPlan(windowIndices: [Int]) -> LockstepWindowPlan? {
        guard let firstIndex = windowIndices.first,
              let firstValue = sequence[firstIndex].value else { return nil }

        let tag = firstValue.choice.tag

        // All entries must share the same tag.
        var idx = 1
        while idx < windowIndices.count {
            guard let value = sequence[windowIndices[idx]].value,
                  value.choice.tag == tag else { return nil }
            idx += 1
        }

        let currentBP = firstValue.choice.bitPattern64
        let targetBP = firstValue.choice.reductionTarget(in: firstValue.validRange)
        guard currentBP != targetBP else { return nil }

        let usesFloatingSteps = tag.isFloatingPoint
        let searchUpward: Bool
        let distance: UInt64
        if usesFloatingSteps {
            guard case let .floating(currentFloat, _, _) = firstValue.choice else { return nil }
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBP),
                tag: tag
            )
            guard case let .floating(targetFloat, _, _) = targetChoice,
                  currentFloat.isFinite,
                  targetFloat.isFinite else { return nil }
            searchUpward = targetFloat > currentFloat
            let rawDistance = abs(currentFloat - targetFloat).rounded(.down)
            guard rawDistance >= 1 else { return nil }
            distance = UInt64(rawDistance)
        } else {
            searchUpward = targetBP > currentBP
            distance = searchUpward ? targetBP - currentBP : currentBP - targetBP
            guard distance >= 1 else { return nil }
        }

        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)] = windowIndices.map { i in
            (i, sequence[i])
        }

        return LockstepWindowPlan(
            windowIndices: windowIndices,
            tag: tag,
            originalEntries: originalEntries,
            searchUpward: searchUpward,
            distance: distance,
            usesFloatingSteps: usesFloatingSteps
        )
    }

    private mutating func nextLockstepProbe(
        state: inout LockstepState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.planIndex < state.plans.count {
            switch state.probePhase {
            case .directShot:
                let plan = state.plans[state.planIndex]
                if let candidate = makeLockstepCandidate(plan: plan, delta: plan.distance) {
                    state.lastEmittedCandidate = candidate
                    state.lastWasDirectShot = true
                    state.probePhase = .binarySearchStart
                    return candidate
                }
                // No valid direct shot — fall through to binary search.
                state.probePhase = .binarySearchStart
                continue

            case .binarySearchStart:
                // If the direct shot was accepted, the plan is done.
                if lastAccepted, state.lastWasDirectShot {
                    state.lastWasDirectShot = false
                    state.planIndex += 1
                    state.probePhase = .directShot
                    continue
                }
                state.lastWasDirectShot = false

                let plan = state.plans[state.planIndex]
                state.stepper = MaxBinarySearchStepper(lo: 0, hi: plan.distance)
                guard let firstDelta = state.stepper.start() else {
                    state.planIndex += 1
                    state.probePhase = .directShot
                    continue
                }
                state.probePhase = .binarySearch
                if let candidate = makeLockstepCandidate(plan: plan, delta: firstDelta) {
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
                // First probe didn't yield a candidate — advance stepper.
                continue

            case .binarySearch:
                let plan = state.plans[state.planIndex]
                guard let nextDelta = state.stepper.advance(lastAccepted: lastAccepted) else {
                    // Converged — move to next plan.
                    state.planIndex += 1
                    state.probePhase = .directShot
                    continue
                }
                if let candidate = makeLockstepCandidate(plan: plan, delta: nextDelta) {
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
                continue
            }
        }
        return nil
    }

    /// Produces a candidate sequence by shifting all window values toward their reduction target by `delta`.
    private func makeLockstepCandidate(plan: LockstepWindowPlan, delta: UInt64) -> ChoiceSequence? {
        guard delta > 0 else { return nil }

        var candidate = sequence
        var firstDifferenceOrder: ShortlexOrder = .eq
        var hasDifference = false

        var entryOffset = 0
        while entryOffset < plan.originalEntries.count {
            let pair = plan.originalEntries[entryOffset]
            let idx = pair.index
            let originalEntry = pair.entry
            guard let value = originalEntry.value else {
                entryOffset += 1
                continue
            }

            let newChoice: ChoiceValue
            if plan.usesFloatingSteps {
                guard case let .floating(currentFloat, _, _) = value.choice else { return nil }
                let signedDelta = plan.searchUpward ? Double(delta) : -Double(delta)
                let candidateFloat = currentFloat + signedDelta
                guard let floatChoice = Self.lockstepFloatingChoice(
                    from: candidateFloat,
                    tag: plan.tag
                ) else { return nil }
                newChoice = floatChoice
            } else {
                guard plan.searchUpward
                    ? UInt64.max - delta >= value.choice.bitPattern64
                    : value.choice.bitPattern64 >= delta
                else { return nil }

                let newBP = plan.searchUpward
                    ? value.choice.bitPattern64 + delta
                    : value.choice.bitPattern64 - delta
                newChoice = ChoiceValue(
                    plan.tag.makeConvertible(bitPattern64: newBP),
                    tag: plan.tag
                )
            }

            // Skip values that fall outside an explicit range.
            guard value.isRangeExplicit == false || newChoice.fits(in: value.validRange) else {
                entryOffset += 1
                continue
            }

            let newEntry = ChoiceSequenceValue.value(.init(
                choice: newChoice,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
            let order = newEntry.shortLexCompare(originalEntry)
            guard order != .eq else {
                entryOffset += 1
                continue
            }

            if hasDifference == false {
                hasDifference = true
                firstDifferenceOrder = order
            }
            candidate[idx] = newEntry
            entryOffset += 1
        }

        // Only accept candidates whose first difference is a shortlex improvement.
        guard hasDifference, firstDifferenceOrder == .lt else { return nil }
        return candidate
    }

    private static func lockstepFloatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
        switch tag {
        case .double:
            guard value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        case .float16:
            let encoded = Float16Emulation.encodedBitPattern(from: value)
            let reconstructed = Float16Emulation.doubleValue(fromEncoded: encoded)
            guard reconstructed.isFinite else { return nil }
            return .floating(reconstructed, encoded, .float16)
        default:
            return nil
        }
    }

    // MARK: - Mixed Redistribution Math

    /// Builds a ``MixedRedistributionContext`` from current source and sink choices.
    ///
    /// Both sides are converted to rational form with a common denominator. When at least one side is integer, ``MixedRedistributionContext/intStepSize`` equals the denominator so the integer side only takes whole-number deltas.
    static func makeMixedRedistributionContext(
        sourceChoice: ChoiceValue,
        sinkChoice: ChoiceValue,
        sourceValidRange: ClosedRange<UInt64>?,
        sourceIsRangeExplicit: Bool
    ) -> MixedRedistributionContext? {
        guard let sourceRatio = rationalForChoice(sourceChoice),
              let sinkRatio = rationalForChoice(sinkChoice) else {
            return nil
        }

        // Compute source's reduction target as a rational.
        let sourceTargetBP = sourceChoice.reductionTarget(
            in: sourceIsRangeExplicit ? sourceValidRange : nil
        )
        guard let targetRatio = rationalForTarget(
            sourceChoice,
            targetBitPattern: sourceTargetBP
        ) else { return nil }

        guard let lcmAB = leastCommonMultiple(sourceRatio.denominator, sinkRatio.denominator),
              let denominator = leastCommonMultiple(lcmAB, targetRatio.denominator),
              denominator > 0 else { return nil }

        guard let sourceNumerator = scaledNumerator(sourceRatio, to: denominator),
              let sinkNumerator = scaledNumerator(sinkRatio, to: denominator),
              let targetNumerator = scaledNumerator(targetRatio, to: denominator)
        else { return nil }

        let sourceIsInt = isIntegerTag(sourceChoice.tag)
        let sinkIsInt = isIntegerTag(sinkChoice.tag)
        let intStepSize: UInt64 = (sourceIsInt || sinkIsInt) ? denominator : 1
        guard intStepSize > 0 else { return nil }

        let sourceMovesUpward = targetNumerator > sourceNumerator
        let rawDistance = sourceMovesUpward
            ? UInt64(targetNumerator - sourceNumerator)
            : UInt64(sourceNumerator - targetNumerator)
        guard rawDistance > 0 else { return nil }

        let distanceInSteps = rawDistance / intStepSize
        guard distanceInSteps > 0 else { return nil }

        return MixedRedistributionContext(
            sourceNumerator: sourceNumerator,
            sinkNumerator: sinkNumerator,
            denominator: denominator,
            intStepSize: intStepSize,
            sourceMovesUpward: sourceMovesUpward,
            distanceInSteps: distanceInSteps
        )
    }

    /// Applies a delta (in step units) to a mixed pair, producing new source and sink choices.
    static func mixedRedistributedPairChoices(
        sourceChoice: ChoiceValue,
        sinkChoice: ChoiceValue,
        delta: UInt64,
        context: MixedRedistributionContext
    ) -> (ChoiceValue, ChoiceValue)? {
        guard delta <= context.distanceInSteps else { return nil }

        let (actualDelta, stepOverflow) = delta.multipliedReportingOverflow(by: context.intStepSize)
        guard stepOverflow == false, actualDelta <= UInt64(Int64.max) else { return nil }
        let signedDelta = Int64(actualDelta)

        let newSourceNum: Int64
        let newSinkNum: Int64
        if context.sourceMovesUpward {
            let (s, sOverflow) = context.sourceNumerator.addingReportingOverflow(signedDelta)
            let (k, kOverflow) = context.sinkNumerator.subtractingReportingOverflow(signedDelta)
            guard sOverflow == false, kOverflow == false else { return nil }
            newSourceNum = s
            newSinkNum = k
        } else {
            let (s, sOverflow) = context.sourceNumerator.subtractingReportingOverflow(signedDelta)
            let (k, kOverflow) = context.sinkNumerator.addingReportingOverflow(signedDelta)
            guard sOverflow == false, kOverflow == false else { return nil }
            newSourceNum = s
            newSinkNum = k
        }

        guard let newSourceChoice = choiceFromNumerator(
            newSourceNum,
            denominator: context.denominator,
            original: sourceChoice
        ),
            let newSinkChoice = choiceFromNumerator(
                newSinkNum,
                denominator: context.denominator,
                original: sinkChoice
            )
        else { return nil }

        return (newSourceChoice, newSinkChoice)
    }

    // MARK: - Rational arithmetic helpers

    private static func rationalForChoice(
        _ choice: ChoiceValue
    ) -> (numerator: Int64, denominator: UInt64)? {
        switch choice {
        case let .floating(value, _, tag):
            guard value.isFinite else { return nil }
            return FloatReduction.integerRatio(for: value, tag: tag)
        case let .signed(value, _, _):
            return (value, 1)
        case let .unsigned(value, _):
            guard value <= UInt64(Int64.max) else { return nil }
            return (Int64(value), 1)
        }
    }

    private static func rationalForTarget(
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
                  targetValue.isFinite else { return nil }
            return FloatReduction.integerRatio(for: targetValue, tag: tag)
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

    private static func choiceFromNumerator(
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
                  narrowedValue == intValue else { return nil }
            return narrowed
        case let .unsigned(_, tag):
            let denom = Int64(denominator)
            guard denom > 0, numerator % denom == 0 else { return nil }
            let intValue = numerator / denom
            guard intValue >= 0 else { return nil }
            let uintValue = UInt64(intValue)
            let narrowed = ChoiceValue(uintValue, tag: tag)
            guard case let .unsigned(narrowedValue, _) = narrowed,
                  narrowedValue == uintValue else { return nil }
            return narrowed
        }
    }

    private static func scaledNumerator(
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

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }

    private static func leastCommonMultiple(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard lhs > 0, rhs > 0 else { return nil }
        let gcd = greatestCommonDivisor(lhs, rhs)
        let reducedLHS = lhs / gcd
        let (product, overflow) = reducedLHS.multipliedReportingOverflow(by: rhs)
        guard overflow == false else { return nil }
        return product
    }

    private static func floatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
        switch tag {
        case .double:
            guard value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        case .float16:
            let encoded = Float16Emulation.encodedBitPattern(from: value)
            let reconstructed = Float16Emulation.doubleValue(fromEncoded: encoded)
            guard reconstructed.isFinite else { return nil }
            return .floating(reconstructed, encoded, .float16)
        default:
            return nil
        }
    }

    private static func isIntegerTag(_ tag: TypeTag) -> Bool {
        switch tag {
        case .int, .int8, .int16, .int32, .int64,
             .uint, .uint8, .uint16, .uint32, .uint64:
            true
        default:
            false
        }
    }
}
