@testable import ExhaustCore

extension ReductionSearch {
    /// Direct search tests act as the interpreter: lazy candidates are written only by their consumer.
    mutating func nextMaterialized(
        _ feedback: SearchFeedback,
        from baseline: ChoiceSequence,
        into buffer: inout ChoiceSequence
    ) -> ReductionCandidate? {
        let candidate = next(feedback, into: &buffer)
        guard case let .lazy(probe) = candidate?.contents else {
            return candidate
        }
        buffer = baseline
        probe.write(into: &buffer)
        return candidate
    }
}
