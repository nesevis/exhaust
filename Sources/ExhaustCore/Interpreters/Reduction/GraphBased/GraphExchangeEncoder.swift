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
    }

    private struct RedistributionState {
        let pairs: [(sourceIndex: Int, sinkIndex: Int, sourceTag: TypeTag, maxDelta: UInt64)]
        var pairIndex: Int
        var stepper: MaxBinarySearchStepper?
        var didEmitCandidate: Bool
        var lastEmittedCandidate: ChoiceSequence?
        /// Whether the full-delta probe has been tried for the current pair.
        var triedFullDelta: Bool
        /// Whether any probe was accepted during the current pass.
        var anyAcceptedThisPass: Bool
        /// Number of completed passes (capped at ``maxPasses`` to bound work).
        var passCount: Int
    }

    /// Maximum number of redistribution passes before the encoder stops re-evaluating pairs.
    private static let maxPasses = 3

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
        case .tandem:
            break
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
                state.anyAcceptedThisPass = true
            }
            state.lastEmittedCandidate = nil
            let result = nextRedistributionProbe(state: &state, lastAccepted: lastAccepted)
            mode = .redistribution(state)
            return result
        }
    }

    // MARK: - Redistribution

    private mutating func startRedistribution(
        scope: RedistributionScope,
        graph: ChoiceGraph
    ) {
        var pairs: [(sourceIndex: Int, sinkIndex: Int, sourceTag: TypeTag, maxDelta: UInt64)] = []

        for pair in scope.pairs {
            guard let sourceRange = graph.nodes[pair.sourceNodeID].positionRange,
                  let sinkRange = graph.nodes[pair.sinkNodeID].positionRange else {
                continue
            }
            guard case let .chooseBits(sourceMetadata) = graph.nodes[pair.sourceNodeID].kind else {
                continue
            }

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
                sourceTag: sourceMetadata.value.tag,
                maxDelta: maxDelta
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
            anyAcceptedThisPass: false,
            passCount: 0
        ))
    }

    private func nextRedistributionProbe(
        state: inout RedistributionState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.pairIndex < state.pairs.count {
            let pair = state.pairs[state.pairIndex]

            if state.stepper == nil {
                // Recompute maxDelta from the CURRENT sequence — prior pair
                // acceptances may have changed the source's value.
                let currentMaxDelta = currentDelta(
                    sourceIndex: pair.sourceIndex,
                    sourceTag: pair.sourceTag
                )
                guard currentMaxDelta > 0 else {
                    state.pairIndex += 1
                    continue
                }

                // Try full delta first (zero the source completely).
                // If accepted, skip binary search entirely — the source is
                // zeroed and the encoder moves to the next pair. This enables
                // cascading: each zeroed source changes the landscape for
                // subsequent pairs.
                if state.triedFullDelta == false {
                    state.triedFullDelta = true
                    if let candidate = buildRedistributionCandidate(
                        sourceIndex: pair.sourceIndex,
                        sinkIndex: pair.sinkIndex,
                        sourceTag: pair.sourceTag,
                        delta: currentMaxDelta
                    ) {
                        state.didEmitCandidate = true
                        state.lastEmittedCandidate = candidate
                        return candidate
                    }
                    // Full delta rejected — fall through to binary search.
                }

                // Full delta was rejected (or already tried and rejected).
                // Fall back to binary search on delta magnitude.
                state.stepper = MaxBinarySearchStepper(
                    lo: 0,
                    hi: currentMaxDelta
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
                    delta: firstDelta
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
                if let candidate = buildRedistributionCandidate(
                    sourceIndex: pair.sourceIndex,
                    sinkIndex: pair.sinkIndex,
                    sourceTag: pair.sourceTag,
                    delta: nextDelta
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
        // haven't hit the pass cap, reset for another pass — prior
        // acceptances may have created new headroom for earlier pairs.
        state.passCount += 1
        if state.anyAcceptedThisPass, state.passCount < Self.maxPasses {
            state.pairIndex = 0
            state.triedFullDelta = false
            state.stepper = nil
            state.anyAcceptedThisPass = false
            return nextRedistributionProbe(state: &state, lastAccepted: false)
        }

        return nil
    }

    /// Computes the current semantic distance from the source's value to its reduction target.
    private func currentDelta(sourceIndex: Int, sourceTag: TypeTag) -> UInt64 {
        guard let sourceValue = sequence[sourceIndex].value else { return 0 }
        let sourceSemantic = Self.semanticValue(sourceValue.choice)
        let targetSemantic = Self.semanticValue(
            ChoiceValue(
                sourceTag.makeConvertible(
                    bitPattern64: sourceValue.choice.reductionTarget(in: sourceValue.validRange)
                ),
                tag: sourceTag
            )
        )
        let distance = abs(sourceSemantic - targetSemantic)
        return UInt64(clamping: distance)
    }

    /// Builds a redistribution candidate by transferring `delta` units of semantic magnitude from source to sink.
    ///
    /// Operates in semantic (Int64) value space: the source moves toward its reduction target by `delta`, and the sink absorbs the same magnitude in the opposite direction. Both results are converted back to bit patterns and validated against the type's representable range.
    private func buildRedistributionCandidate(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        delta: UInt64
    ) -> ChoiceSequence? {
        guard delta > 0, delta <= UInt64(Int64.max) else { return nil }

        let sourceEntry = sequence[sourceIndex]
        let sinkEntry = sequence[sinkIndex]
        guard let sourceValue = sourceEntry.value else { return nil }
        guard let sinkValue = sinkEntry.value else { return nil }

        // Extract semantic values as Int64 for signed arithmetic.
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

        // Determine direction: source moves toward target.
        let signedDelta = Int64(delta)
        let newSourceSemantic: Int64
        let newSinkSemantic: Int64

        if sourceSemanticValue > targetSemanticValue {
            // Source decreases toward target, sink increases.
            let (candidateSource, sourceOverflow) = sourceSemanticValue.subtractingReportingOverflow(signedDelta)
            let (candidateSink, sinkOverflow) = sinkSemanticValue.addingReportingOverflow(signedDelta)
            guard sourceOverflow == false, sinkOverflow == false else { return nil }
            newSourceSemantic = candidateSource
            newSinkSemantic = candidateSink
        } else {
            // Source increases toward target, sink decreases.
            let (candidateSource, sourceOverflow) = sourceSemanticValue.addingReportingOverflow(signedDelta)
            let (candidateSink, sinkOverflow) = sinkSemanticValue.subtractingReportingOverflow(signedDelta)
            guard sourceOverflow == false, sinkOverflow == false else { return nil }
            newSourceSemantic = candidateSource
            newSinkSemantic = candidateSink
        }

        // Convert back to bit patterns and validate range.
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
}
