/// Which Unicode version's blocks `.character()` and `.string()` draw from.
///
/// The version is part of the generated domain, not an implementation detail. Adopting a newer one adds blocks, which moves every flat index above the first addition and stops recorded replay seeds naming the character they named before. Choosing it at the call site keeps that a decision rather than something a toolchain update does silently.
public enum UnicodeVersion: Sendable, CaseIterable {
    /// Unicode 17.0, published 2025-08-27.
    case v17

    /// The block ranges this version draws from, less surrogates, private use, and noncharacters.
    var scalarRanges: [ClosedRange<UInt32>] {
        switch self {
            case .v17: unicode17ScalarRanges
        }
    }

    /// Built once per version. Reduces toward space (U+0020).
    var scalarRangeSet: ScalarRangeSet {
        switch self {
            case .v17: unicode17ScalarRangeSet
        }
    }
}

private let unicode17ScalarRangeSet: ScalarRangeSet = {
    var rangeSet = ExhaustRangeSet<UInt32>()
    for range in unicode17ScalarRanges {
        rangeSet.insert(contentsOf: range.lowerBound ..< (range.upperBound + 1))
    }
    return ScalarRangeSet(rangeSet, bottomCodepoint: " ")
}()
