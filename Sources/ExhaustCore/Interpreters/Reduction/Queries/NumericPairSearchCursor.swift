/// Visits diagonals of each pair's candidate grid, sharing every diagonal across pairs before deepening the search.
///
/// Rejection never removes an interval: isolated failure points remain reachable within the bounded domain samples. The cursor owns no candidate sequence copies.
struct NumericPairSearchCursor {
    private struct Plan {
        let pair: NumericPairQuery.Pair
        let sources: [UInt64]
        let sinks: [UInt64]
    }

    private let plans: [Plan]
    private var diagonal = 0
    private var sourceOffset = 0
    private var planIndex = 0
    private let maximumDiagonal: Int

    init(pairs: [NumericPairQuery.Pair]) {
        var sourceSamples: [Int: [UInt64]] = [:]
        var sinkSamples: [Int: [UInt64]] = [:]
        plans = pairs.map { pair in
            let sources = sourceSamples[pair.source.position]
                ?? NumericPairCandidates.values(for: pair.source, simplifying: true)
            let sinks = sinkSamples[pair.sink.position]
                ?? NumericPairCandidates.values(for: pair.sink, simplifying: false)
            sourceSamples[pair.source.position] = sources
            sinkSamples[pair.sink.position] = sinks
            return Plan(
                pair: pair,
                sources: sources,
                sinks: sinks
            )
        }
        maximumDiagonal = plans.map { $0.sources.count + $0.sinks.count - 2 }.max() ?? -1
    }

    /// The pair a probe edits and the bit patterns written into its candidate.
    struct Proposal {
        let pair: NumericPairQuery.Pair
        let sourceBitPattern: UInt64
        let sinkBitPattern: UInt64
    }

    /// Writes exactly two values into a buffer reset to the checkpoint by the caller.
    mutating func next(into candidate: inout ChoiceSequence) -> Proposal? {
        while diagonal <= maximumDiagonal {
            while sourceOffset <= diagonal {
                while planIndex < plans.count {
                    let plan = plans[planIndex]
                    planIndex += 1
                    let sinkOffset = diagonal - sourceOffset
                    guard sourceOffset < plan.sources.count, sinkOffset < plan.sinks.count else {
                        continue
                    }
                    let proposal = Proposal(
                        pair: plan.pair,
                        sourceBitPattern: plan.sources[sourceOffset],
                        sinkBitPattern: plan.sinks[sinkOffset]
                    )
                    candidate[plan.pair.source.position] = candidate[plan.pair.source.position]
                        .withBitPattern(proposal.sourceBitPattern)
                    candidate[plan.pair.sink.position] = candidate[plan.pair.sink.position]
                        .withBitPattern(proposal.sinkBitPattern)
                    return proposal
                }
                planIndex = 0
                sourceOffset += 1
            }
            sourceOffset = 0
            diagonal += 1
        }
        return nil
    }
}
