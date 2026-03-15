/// Detects whether `validRange` metadata varies across sampled choice trees.
///
/// When ranges are constant across samples, the generator has static ranges
/// and the covariant sweep can skip re-derivation after value changes. When
/// ranges vary (or insufficient samples exist), the conservative default is
/// to assume dynamic dependencies and always re-derive.
public enum RangeDependencyDetector {
    /// Returns `true` if any `.choice` node's `validRange` varies across the sample trees,
    /// or if there are too few samples to determine stability.
    ///
    /// - Walks the first tree to collect `(Fingerprint, ClosedRange<UInt64>?)` for `.choice` nodes.
    /// - Compares subsequent trees at the same fingerprints.
    /// - Returns `true` on the first mismatch, or if fingerprint sets differ between trees.
    /// - Returns `true` for fewer than 2 samples (conservative default).
    public static func hasDynamicRanges(in trees: [ChoiceTree]) -> Bool {
        guard trees.count >= 2 else { return true }

        // Collect ranges from the first tree as the reference,
        // only for nodes with explicit ranges (not size-scaled).
        var referenceRanges: [Fingerprint: ClosedRange<UInt64>?] = [:]
        for element in trees[0].walk() {
            switch element.node {
            case let .choice(_, metadata) where metadata.isRangeExplicit:
                referenceRanges[element.fingerprint] = metadata.validRange
            case let .sequence(_, _, metadata) where metadata.isRangeExplicit:
                referenceRanges[element.fingerprint] = metadata.validRange
            default:
                break
            }
        }

        guard referenceRanges.isEmpty == false else { return false }

        // Compare each subsequent tree against the reference.
        for tree in trees.dropFirst() {
            var matchedFingerprints = 0
            for element in tree.walk() {
                let range: ClosedRange<UInt64>?
                switch element.node {
                case let .choice(_, metadata) where metadata.isRangeExplicit:
                    range = metadata.validRange
                case let .sequence(_, _, metadata) where metadata.isRangeExplicit:
                    range = metadata.validRange
                default:
                    continue
                }

                if let referenceRange = referenceRanges[element.fingerprint] {
                    // Fingerprint exists in reference — compare ranges.
                    if range != referenceRange {
                        return true
                    }
                    matchedFingerprints += 1
                }
                // Fingerprints not in reference are ignored (new structural paths).
            }

            // If the set of choice fingerprints differs structurally
            // (reference has fingerprints this tree doesn't), that suggests
            // dynamic behavior from different branch selections.
            if matchedFingerprints < referenceRanges.count {
                return true
            }
        }

        return false
    }
}
