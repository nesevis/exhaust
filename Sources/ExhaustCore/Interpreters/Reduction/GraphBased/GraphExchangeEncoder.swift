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
    private var sequence: ChoiceSequence = .init()
    /// Maps the sequence index of every leaf the current scope can touch to its graph node ID and bind-inner reshape marker. Built once at ``start(scope:)`` time and read by ``nextProbe(lastAccepted:)`` to construct ``ProjectedMutation/leafValues(_:)`` reports without diffing the entire sequence.
    private var leafLookup: [Int: (nodeID: Int, mayReshape: Bool)] = [:]
    /// The original scope kind seen at ``start(scope:)`` time. Stored so ``refreshScope(graph:sequence:)`` can re-derive a fresh exchange scope from the live graph against the same kind (redistribution vs tandem) when an in-pass structural mutation invalidates the cached pair / lockstep state. The current redistribution and lockstep states are not preserved across a refresh because their pair indices reference pre-mutation positions; the refresh re-builds them from scratch via ``ChoiceGraph/exchangeScopes()``.
    private var originalExchangeKind: ExchangeScopeKind = .none

    /// Discriminator for which exchange scope shape the encoder was started against. Used by ``refreshScope(graph:sequence:)`` to find the corresponding scope in the live graph's ``ChoiceGraph/exchangeScopes()`` result.
    private enum ExchangeScopeKind {
        case none
        case redistribution
        case lockstep
    }

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

    /// Maximum number of redistribution passes before the encoder stops re-evaluating pairs. With targeted re-evaluation (only accepted pairs), subsequent passes are cheap — O(log maxDelta) probes per accepted pair. The investigation doc proposed cutting this to 1 as Fix C, but bisection (16 → 8 → 1) showed that 16 is the optimum: at maxPasses=8 Bound5 already regresses (+8% mats, +6% reduce time, −7% accepts) because some pair binary searches need 9–16 passes to converge, and at maxPasses=1 the regression is catastrophic (+143% mats, +129% reduce time). All other workloads complete pair convergence in ≤1 pass, so the multi-pass replay is inert there — it adds zero cost where it isn't needed and is load-bearing where it is.
    private static let maxPasses = 16

    /// Cap on the number of redistribution pairs probed per scope. Bisection (240 → 120 → 60 → 30 → 16) located the inflection between 30 and 16. At cap=30 ComplexGrammar reached 27,716 ms (vs Bonsai's ~33,000 ms and the cap=240 baseline of ~30,000 ms); at cap=16 it crept back up to 27,830 ms with no compensating benefit. Bound5 acc loss at cap=30 was functionally invisible (no CE quality change, no reduce time change, same canonical CE) — the lost accepts were trailing-edge progress that did not change the eventual outcome. Bonsai's ``RedistributeAcrossValueContainersEncoder`` uses 240 in its `estimatedCost`, but Graph's per-probe cost profile and outer reducer scheduling make 30 the right value here.
    private static let maxPairsPerScope = 30

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        sequence = scope.baseSequence
        mode = .idle
        leafLookup = [:]
        originalExchangeKind = .none

        guard case let .exchange(exchangeScope) = scope.transformation.operation else {
            return
        }

        let graph = scope.graph
        populateLeafLookup(from: exchangeScope, graph: graph)

        switch exchangeScope {
        case let .redistribution(redistScope):
            originalExchangeKind = .redistribution
            startRedistribution(scope: redistScope, graph: graph)
        case let .tandem(tandemScope):
            originalExchangeKind = .lockstep
            startLockstep(scope: tandemScope, graph: graph)
        }
    }

    mutating func refreshScope(graph: ChoiceGraph, sequence newSequence: ChoiceSequence) {
        // Re-derive the encoder's working set from the live graph after a
        // structural mutation. The pair list (RedistributionState) and the
        // lockstep plans (LockstepState) reference pre-mutation graph node
        // IDs and sequence positions; without a refresh the next probe
        // would address tombstoned nodes or shifted-out positions. The
        // refresh discards in-flight pair / plan state, replays the live
        // graph through ``ChoiceGraph/exchangeScopes()``, and re-runs the
        // appropriate ``startRedistribution`` / ``startLockstep`` against
        // the live state. New leaves the splice created enter the new
        // pair list naturally because ``exchangeScopes()`` walks the
        // current ``typeCompatibilityEdges`` set.
        sequence = newSequence
        mode = .idle
        leafLookup = [:]

        guard originalExchangeKind != .none else { return }

        let scopes = graph.exchangeScopes()
        switch originalExchangeKind {
        case .none:
            return
        case .redistribution:
            let redistribution = scopes.firstNonNil { scope -> RedistributionScope? in
                if case let .redistribution(inner) = scope { return inner }
                return nil
            }
            guard let redistribution else { return }
            populateLeafLookup(from: .redistribution(redistribution), graph: graph)
            startRedistribution(scope: redistribution, graph: graph)
        case .lockstep:
            let tandem = scopes.firstNonNil { scope -> TandemScope? in
                if case let .tandem(inner) = scope { return inner }
                return nil
            }
            guard let tandem else { return }
            populateLeafLookup(from: .tandem(tandem), graph: graph)
            startLockstep(scope: tandem, graph: graph)
        }
    }

    /// Builds the (sequence index → nodeID, mayReshape) lookup once for both redistribution and lockstep modes. The wrapping ``nextProbe(lastAccepted:)`` reads it to construct ``ProjectedMutation/leafValues(_:)`` reports.
    private mutating func populateLeafLookup(from exchangeScope: ExchangeScope, graph: ChoiceGraph) {
        switch exchangeScope {
        case let .redistribution(redistScope):
            for pair in redistScope.pairs {
                if let range = graph.nodes[pair.source.nodeID].positionRange {
                    leafLookup[range.lowerBound] = (pair.source.nodeID, pair.source.mayReshapeOnAcceptance)
                }
                if let range = graph.nodes[pair.sink.nodeID].positionRange {
                    leafLookup[range.lowerBound] = (pair.sink.nodeID, pair.sink.mayReshapeOnAcceptance)
                }
            }
        case let .tandem(tandemScope):
            for group in tandemScope.groups {
                for entry in group.leaves {
                    if let range = graph.nodes[entry.nodeID].positionRange {
                        leafLookup[range.lowerBound] = (entry.nodeID, entry.mayReshapeOnAcceptance)
                    }
                }
            }
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
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
            guard let candidate = nextRedistributionProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .redistribution(state)
                return nil
            }
            mode = .redistribution(state)
            return EncoderProbe(
                candidate: candidate,
                mutation: buildLeafValuesMutation(candidate: candidate)
            )
        case var .lockstep(state):
            if lastAccepted, let accepted = state.lastEmittedCandidate {
                sequence = accepted
            }
            state.lastEmittedCandidate = nil
            guard let candidate = nextLockstepProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .lockstep(state)
                return nil
            }
            mode = .lockstep(state)
            return EncoderProbe(
                candidate: candidate,
                mutation: buildLeafValuesMutation(candidate: candidate)
            )
        }
    }

    /// Constructs a `.leafValues` mutation report by walking ``leafLookup`` and recording each entry whose value differs between the candidate and the current baseline.
    private func buildLeafValuesMutation(candidate: ChoiceSequence) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for (sequenceIndex, info) in leafLookup {
            guard sequenceIndex < candidate.count, sequenceIndex < sequence.count else { continue }
            guard let candidateChoice = candidate[sequenceIndex].value?.choice,
                  let baselineChoice = sequence[sequenceIndex].value?.choice
            else { continue }
            guard candidateChoice != baselineChoice else { continue }
            changes.append(LeafChange(
                leafNodeID: info.nodeID,
                newValue: candidateChoice,
                mayReshape: info.mayReshape
            ))
        }
        return .leafValues(changes)
    }

    // MARK: - Redistribution

    private mutating func startRedistribution(
        scope: RedistributionScope,
        graph: ChoiceGraph
    ) {
        var pairs: [(sourceIndex: Int, sinkIndex: Int, sourceTag: TypeTag, sinkTag: TypeTag, maxDelta: UInt64, mixedContext: MixedRedistributionContext?)] = []

        for pair in scope.pairs {
            guard let sourceRange = graph.nodes[pair.sourceNodeID].positionRange,
                  let sinkRange = graph.nodes[pair.sinkNodeID].positionRange
            else {
                continue
            }
            guard case let .chooseBits(sourceMetadata) = graph.nodes[pair.sourceNodeID].kind,
                  case let .chooseBits(sinkMetadata) = graph.nodes[pair.sinkNodeID].kind
            else {
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

        // Largest-delta pairs first: high-impact consolidation pairs get probed
        // before trivial distance=1 pairs. Mirrors the orientation sort in
        // ``RedistributeAcrossValueContainersEncoder``, which uses the same
        // source-distance ordering. Without this, the encoder would walk pairs
        // in `typeCompatibilityEdges` insertion order — node-traversal order,
        // not value-distance order — and burn its budget on low-yield tail
        // pairs before reaching the easy wins.
        pairs.sort { $0.maxDelta > $1.maxDelta }

        // Cap the working set to mirror Bonsai's `estimatedCost` ceiling of
        // 240 pairs. After sorting, the prefix is the highest-yield slice; the
        // tail is the long stretch of low-distance pairs whose acceptance rate
        // is near zero on workloads with many type-compatible leaves.
        if pairs.count > Self.maxPairsPerScope {
            pairs.removeLast(pairs.count - Self.maxPairsPerScope)
        }

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
        sourceTag _: TypeTag,
        sinkTag _: TypeTag,
        usesMixed: Bool
    ) -> (maxDelta: UInt64, mixedContext: MixedRedistributionContext?) {
        guard let sourceValue = sequence[sourceIndex].value else {
            return (0, nil)
        }

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
    /// For pairs with a ``MixedRedistributionContext`` (cross-type or floating-point), uses rational arithmetic with a common denominator. For same-tag integer pairs, operates in UInt64 bit-pattern space — modular wraparound when the sink's declared domain equals its natural type width, validation-with-rejection when the sink has an explicit narrow range. See `graph-exchange-semantic-cast-removal.md` for the rationale behind the same-tag arithmetic choices.
    private func buildRedistributionCandidate(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        sinkTag _: TypeTag,
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
        // The gate is on the sink, not the source. The source moves toward
        // its own reduction target — a contraction inside `[min(currentBP,
        // targetBP), max(currentBP, targetBP)]` — so its new bp never leaves
        // the source's own valid range regardless of whether that range is
        // narrow or full-width. The sink is the side that can escape its
        // valid range as it absorbs the opposing delta, so the sink is the
        // side that determines which sub-path we take.
        //
        // When the sink's declared domain equals the natural type width, we
        // use bit-pattern modular arithmetic with a width-aware mask. This
        // matches the wrapping arithmetic (`&+`/`&-`) the property under test
        // likely uses for the same type and lets redistribution reach
        // boundary counterexamples like `(Int16.min, -1)` that semantic-space
        // arithmetic would reject as overflow. See
        // `bound5-redistribution-wraparound-diagnosis.md` for the motivating
        // trace.
        //
        // When the sink carries an explicit narrow range, we still operate
        // in UInt64 bit-pattern space (signed types are biased via the
        // `signBitMask` XOR in their `BitPatternConvertible` conformance, so
        // additive arithmetic in biased space matches semantic arithmetic),
        // but we use overflow-checked operations and reject — rather than
        // wrap — any candidate that lands outside the sink's `validRange` or
        // the type's natural bounds. See
        // `graph-exchange-semantic-cast-removal.md` for the rationale and
        // for the discussion of the latent bugs in the previous
        // semantic-Int64 implementation that this rewrite addresses.
        let sourceBP = sourceValue.choice.bitPattern64
        let sinkBP = sinkValue.choice.bitPattern64
        let targetBP = sourceValue.choice.reductionTarget(in: sourceValue.validRange)

        if sinkValue.allowsModularArithmetic {
            let mask = sinkValue.choice.tag.bitPatternRange.upperBound
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

        // Narrow-sink fallback: UInt64 bit-pattern arithmetic with explicit
        // bounds enforcement.
        let newSourceBP: UInt64
        let newSinkBP: UInt64
        if sourceBP > targetBP {
            // Source moves down (toward target), sink moves up.
            // The encoder bounds delta to `currentMaxDelta`'s `distance =
            // sourceBP - targetBP`, and `targetBP >= 0`, so this subtraction
            // cannot underflow. Defensive guard against stale state.
            guard sourceBP >= delta else { return nil }
            newSourceBP = sourceBP - delta
            let (sinkSum, sinkOverflow) = sinkBP.addingReportingOverflow(delta)
            guard sinkOverflow == false else { return nil }
            newSinkBP = sinkSum
        } else {
            // Source moves up (toward target), sink moves down.
            let (sourceSum, sourceOverflow) = sourceBP.addingReportingOverflow(delta)
            guard sourceOverflow == false else { return nil }
            newSourceBP = sourceSum
            guard sinkBP >= delta else { return nil }
            newSinkBP = sinkBP - delta
        }

        // Enforce natural type bounds. Replaces the per-tag range checks
        // that the deleted `bitPattern(fromSemantic:tag:)` helper used to
        // do — `tag.bitPatternRange` is the same set, so this is a
        // structural simplification, not a behavior change.
        guard sourceTag.bitPatternRange.contains(newSourceBP),
              sinkValue.choice.tag.bitPatternRange.contains(newSinkBP)
        else {
            return nil
        }

        // Enforce explicit `validRange`. The mixed/rational path already
        // does this for cross-type and float pairs; the previous
        // semantic-Int64 narrow-sink path was missing this check, which
        // let candidates escape the user's declared domain.
        if sourceValue.isRangeExplicit,
           let range = sourceValue.validRange,
           range.contains(newSourceBP) == false
        {
            return nil
        }
        if sinkValue.isRangeExplicit,
           let range = sinkValue.validRange,
           range.contains(newSinkBP) == false
        {
            return nil
        }

        var candidate = sequence
        candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBP)
        candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBP)
        return candidate
    }

    // MARK: - Lockstep Reduction

    /// Builds suffix-window plans from each tandem group and dispatches the lockstep state.
    ///
    /// For each group of same-tag leaves, generates plans that drop progressively more leading entries — this prevents a near-target leader from blocking the whole set.
    private mutating func startLockstep(scope: TandemScope, graph: ChoiceGraph) {
        var plans: [LockstepWindowPlan] = []

        for group in scope.groups {
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
    ///
    /// Returns `nil` when any window index has become stale relative to the current sequence — a defensive guard against structural refreshes that happened between scope construction and plan building.
    private func makeLockstepWindowPlan(windowIndices: [Int]) -> LockstepWindowPlan? {
        guard let firstIndex = windowIndices.first,
              firstIndex < sequence.count,
              let firstValue = sequence[firstIndex].value else { return nil }

        let tag = firstValue.choice.tag

        // All entries must share the same tag.
        var idx = 1
        while idx < windowIndices.count {
            let windowIndex = windowIndices[idx]
            guard windowIndex < sequence.count,
                  let value = sequence[windowIndex].value,
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
              let sinkRatio = rationalForChoice(sinkChoice)
        else {
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
