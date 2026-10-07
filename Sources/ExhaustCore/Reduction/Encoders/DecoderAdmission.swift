/// Adds candidate-specific feasibility checks to exact decoding. Only ``SequenceDecoder/exact(materializePicks:admission:)`` carries one, so guided decoding cannot silently drop it.
enum DecoderAdmission {
    case standard
    case numericPair(NumericPairQuery.Pair)
    case numericJoint([NumericPairQuery.Leaf])

    /// Whether the admission inspects the decoded history. Only exact decoding produces a history to inspect, and only then does value-only decoding need to build it.
    var inspectsDecodedHistory: Bool {
        switch self {
            case .standard:
                false
            case .numericPair, .numericJoint:
                true
        }
    }

    /// Requires every numeric edit to survive decoding verbatim and improve the checkpoint, so a clamped edit never reaches the property.
    ///
    /// Equality compares choices and markers, not range metadata. Fresh bounds can change while all requested edits and every structural marker remain intact.
    func admits(decoded: ChoiceSequence, candidate: ChoiceSequence, original: ChoiceSequence) -> Bool {
        switch self {
            case .standard:
                true
            case .numericPair, .numericJoint:
                decoded == candidate && decoded.shortLexPrecedes(original)
        }
    }

    /// Rejects a surviving failure when dependent generators moved an edited leaf to a different bind site.
    func admits(tree: ChoiceTree) -> Bool {
        switch self {
            case .standard:
                true
            case let .numericPair(pair):
                NumericPairQuery.preservesIdentity(of: pair, in: tree)
            case let .numericJoint(leaves):
                NumericPairQuery.preservesIdentity(of: leaves, in: tree)
        }
    }
}
