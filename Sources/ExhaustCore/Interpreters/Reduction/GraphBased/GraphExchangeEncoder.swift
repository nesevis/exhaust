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
    }

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
            lastEmittedCandidate: nil
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
                // First probe not viable — advance stepper.
            }

            let feedback = state.didEmitCandidate ? lastAccepted : false
            state.didEmitCandidate = false

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
        }

        return nil
    }

    /// Computes the current distance from the source's value to its reduction target, reading from the live sequence.
    private func currentDelta(sourceIndex: Int, sourceTag: TypeTag) -> UInt64 {
        guard let sourceValue = sequence[sourceIndex].value else { return 0 }
        let target = sourceValue.choice.reductionTarget(in: sourceValue.validRange)
        let bitPattern = sourceValue.choice.bitPattern64
        return bitPattern > target ? bitPattern - target : target - bitPattern
    }

    /// Builds a redistribution candidate by moving `delta` bit-pattern units from source to sink.
    ///
    /// The source's bit pattern decreases by delta (toward its reduction target). The sink's bit pattern increases by delta (absorbing the magnitude). Both use the Bonsai bit-pattern arithmetic convention.
    private func buildRedistributionCandidate(
        sourceIndex: Int,
        sinkIndex: Int,
        sourceTag: TypeTag,
        delta: UInt64
    ) -> ChoiceSequence? {
        guard delta > 0 else { return nil }

        let sourceEntry = sequence[sourceIndex]
        let sinkEntry = sequence[sinkIndex]
        guard let sourceValue = sourceEntry.value else { return nil }
        guard let sinkValue = sinkEntry.value else { return nil }

        let sourceBitPattern = sourceValue.choice.bitPattern64
        let sinkBitPattern = sinkValue.choice.bitPattern64
        let sourceTarget = sourceValue.choice.reductionTarget(in: sourceValue.validRange)

        // Determine direction: source moves toward target.
        let newSourceBP: UInt64
        let newSinkBP: UInt64
        if sourceBitPattern > sourceTarget {
            // Source decreases, sink increases.
            guard sourceBitPattern >= delta else { return nil }
            guard UInt64.max - delta >= sinkBitPattern else { return nil }
            newSourceBP = sourceBitPattern - delta
            newSinkBP = sinkBitPattern + delta
        } else {
            // Source increases toward target, sink decreases.
            guard UInt64.max - delta >= sourceBitPattern else { return nil }
            guard sinkBitPattern >= delta else { return nil }
            newSourceBP = sourceBitPattern + delta
            newSinkBP = sinkBitPattern - delta
        }

        var candidate = sequence
        candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(newSourceBP)
        candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(newSinkBP)

        return candidate
    }
}
