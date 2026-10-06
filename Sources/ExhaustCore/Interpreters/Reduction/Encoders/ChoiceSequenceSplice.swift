/// Defers copying a complete candidate until a consumer probes the replacement.
///
/// The range addresses the shared baseline, not the replacement's local indices. Replacement storage can be shared by all scopes that use the same donor.
struct ChoiceSequenceSplice {
    let range: ClosedRange<Int>
    let replacement: ChoiceSequence

    func applying(to sequence: ChoiceSequence) -> ChoiceSequence {
        var candidate = sequence
        candidate.replaceSubrange(range, with: replacement)
        return candidate
    }
}
