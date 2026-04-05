//
//  GraphExchangeEncoder.swift
//  Exhaust
//

// MARK: - Graph Exchange Encoder

/// Moves magnitude between leaves to enable future structural operations.
///
/// Operates in two modes based on the ``ExchangeScope``:
/// - **Redistribution**: speculative value swaps along type-compatibility edges. Zeroes the source and transfers the delta to the sink. The intermediate may be shortlex-larger (approximate reduction with affine slack).
/// - **Tandem**: lockstep reduction of same-typed sibling values via suffix-window plans and ``MaxBinarySearchStepper``.
///
/// This is an active-path operation: all target leaves have position ranges in the current sequence.
struct GraphExchangeEncoder: GraphEncoder {
    let name: EncoderName = .graphRedistribution

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        candidateIndex = 0
        candidates = []

        guard case let .exchange(exchangeScope) = scope.transformation.operation else {
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch exchangeScope {
        case let .redistribution(redistScope):
            buildRedistributionCandidates(
                scope: redistScope,
                sequence: sequence,
                graph: graph
            )
        case .tandem:
            // Tandem: stub for now — the full suffix-window + MaxBinarySearchStepper
            // logic will be ported in a later pass.
            break
        }
    }

    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Redistribution

    private mutating func buildRedistributionCandidates(
        scope: RedistributionScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        let maxPairs = min(24, scope.pairs.count)
        for index in 0 ..< maxPairs {
            let pair = scope.pairs[index]
            guard let sourceRange = graph.nodes[pair.sourceNodeID].positionRange,
                  let sinkRange = graph.nodes[pair.sinkNodeID].positionRange else {
                continue
            }
            guard case let .chooseBits(sourceMetadata) = graph.nodes[pair.sourceNodeID].kind,
                  case let .chooseBits(sinkMetadata) = graph.nodes[pair.sinkNodeID].kind else {
                continue
            }

            let sourceTarget = sourceMetadata.value.reductionTarget(in: sourceMetadata.validRange)
            let sourceDelta = sourceMetadata.value.bitPattern64 > sourceTarget
                ? sourceMetadata.value.bitPattern64 - sourceTarget
                : sourceTarget - sourceMetadata.value.bitPattern64

            guard sourceDelta > 0 else { continue }

            // Zero the source, transfer delta to sink.
            var candidate = sequence
            candidate[sourceRange.lowerBound] = candidate[sourceRange.lowerBound]
                .withBitPattern(sourceTarget)

            let sinkNewValue = sinkMetadata.value.bitPattern64 + sourceDelta
            candidate[sinkRange.lowerBound] = candidate[sinkRange.lowerBound]
                .withBitPattern(sinkNewValue)

            // Exchange may make the sequence shortlex-larger (approximate reduction).
            // The shortlex check is done by the decoder, not here.
            candidates.append(candidate)
        }
    }
}
