/// Adds candidate-specific feasibility checks to exact decoding. Only ``SequenceDecoder/exact(materializePicks:admission:)`` carries one, so guided decoding cannot silently drop it.
enum DecoderAdmission {
    case standard
    case numericPair(NumericPairQuery.Pair)

    /// Whether the admission inspects the decoded history. Only exact decoding produces a history to inspect, and only then does value-only decoding need to build it.
    var inspectsDecodedHistory: Bool {
        switch self {
            case .standard:
                false
            case .numericPair:
                true
        }
    }

    /// Requires both numeric edits to survive decoding verbatim and improve the checkpoint, so a clamped edit never reaches the property.
    ///
    /// Equality compares choices and markers, not range metadata. Fresh bounds can change while both requested edits and every structural marker remain intact.
    func admits(decoded: ChoiceSequence, candidate: ChoiceSequence, original: ChoiceSequence) -> Bool {
        switch self {
            case .standard:
                true
            case .numericPair:
                decoded == candidate && decoded.shortLexPrecedes(original)
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
