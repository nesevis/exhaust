/// Flips the sign of every member of a selected numeric group, preserving exact magnitudes in either sign direction.
///
/// A group is indivisible: an unrepresentable negation or an out-of-range counterpart suppresses the whole proposal. Only flips whose earliest changed leaf is negative are proposed, because making that leaf negative can never precede the checkpoint in shortlex order. Exact numeric admission still checks replay before the property runs.
enum SignFlipProposal {
    /// Ranks a sign flip below every ``NumericCommonDivisorProposal`` priority, so the staged cursors try every group's flip before any rescaling.
    static let priority = -1

    /// Builds one sign flip for this pair or higher-order group, leaving unrelated leaves untouched.
    static func build(leaves: [ReductionLeaf]) -> SparseEncoderProbe? {
        var patterns: [UInt64] = []
        for leaf in leaves {
            guard let pattern = counterpart(of: leaf.choice), leaf.range.contains(pattern) else {
                return nil
            }
            patterns.append(pattern)
        }
        let changedIndices = leaves.indices.filter { patterns[$0] != leaves[$0].choice.bitPattern64 }
        guard let earliestChanged = changedIndices.min(by: { leaves[$0].position < leaves[$1].position }),
              leaves[earliestChanged].choice.hasNegativeSign
        else {
            return nil
        }
        return SparseEncoderProbe(leaves: leaves, patterns: patterns)
    }

    /// Flips the signs of non-NaN floats and of signed integers other than their unpaired minimum; unsigned zero can remain in a group unchanged.
    private static func counterpart(of choice: ChoiceValue) -> UInt64? {
        let tag = choice.tag
        if tag.isFloatingPoint, choice.decodedDoubleValue.isNaN {
            return nil
        }
        if tag.isFloatingPoint || tag.isSigned {
            return choice.signFlipped?.bitPattern64
        }
        guard choice.bitPattern64 == 0 else {
            return nil
        }
        return 0
    }
}
