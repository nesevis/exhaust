/// Adds candidate-specific feasibility checks to exact decoding. Only ``SequenceDecoder/exact(materializePicks:admission:)`` carries one, so guided decoding cannot silently drop it.
enum DecoderAdmission {
    case standard
    case numericPair(NumericPairQuery.Pair)

    /// Only exact decoding can apply a non-standard admission.
    var requiresExactDecoding: Bool {
        switch self {
            case .standard:
                false
            case .numericPair:
                true
        }
    }

    /// The value-only materialization outcome after admission, before the property runs.
    enum Materialization {
        case admitted(output: Any, decodingReport: DecodingReport?)
        case rejected(decodingReport: DecodingReport?)
    }

    /// Materializes without a tree. Pair admission also requires both numeric edits to survive decoding verbatim and improve the checkpoint, so a clamped edit never reaches the property.
    func materialize(
        _ generator: AnyGenerator,
        context: consuming Materializer.Context,
        candidate: ChoiceSequence,
        original: ChoiceSequence
    ) -> Materialization {
        switch self {
            case .standard:
                switch Materializer.materializeAny(generator, context: consume context) {
                    case let .success(output, _, report):
                        return .admitted(output: output, decodingReport: report)
                    case let .rejected(report), let .failed(report):
                        return .rejected(decodingReport: report)
                }
            case .numericPair:
                switch Materializer.materializeAnyFlat(generator, context: consume context) {
                    case let .success(output, decoded, report):
                        // Equality compares choices and markers, not range metadata. Fresh bounds can change while both requested edits and every structural marker remain intact.
                        guard decoded == candidate, decoded.shortLexPrecedes(original) else {
                            return .rejected(decodingReport: report)
                        }
                        return .admitted(output: output, decodingReport: report)
                    case let .rejected(report), let .failed(report):
                        return .rejected(decodingReport: report)
                }
        }
    }

    /// Rejects a surviving failure when dependent generators moved either leaf to a different bind site.
    func admits(tree: ChoiceTree) -> Bool {
        switch self {
            case .standard:
                true
            case let .numericPair(pair):
                NumericPairQuery.preservesIdentity(of: pair, in: tree)
        }
    }
}
