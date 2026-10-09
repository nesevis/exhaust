/// Separates a candidate already written into the caller's buffer from leaf edits that can be checked against the rejection cache before writing.
enum PreparedEncoderProbe {
    case materialized(EncoderProbe)
    case sparse(SparseEncoderProbe, baseSequence: ChoiceSequence)

    var mutation: EncoderProbe {
        switch self {
            case let .materialized(mutation):
                mutation
            case let .sparse(probe, _):
                probe.mutation
        }
    }

    /// Supports callers that need every complete candidate, including cached probes, using the same prepared stream as sessions.
    func write(into candidate: inout ChoiceSequence) -> EncoderProbe {
        switch self {
            case let .materialized(mutation):
                return mutation
            case let .sparse(probe, baseSequence):
                candidate = baseSequence
                probe.write(into: &candidate)
                return probe.mutation
        }
    }
}
