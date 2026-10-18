/// Samples exact integer rescalings without assuming that the property is homogeneous. All proposals scale the primitive tuple, so rounding never changes its ratios; the decoder and property still certify each coordinated change.
enum NumericCommonDivisorProposal {
    static let maximumGeometricSteps = 8
    static let maximumProposals = 15

    /// Shares tactic priority across groups, including when domain checks omit earlier scales.
    struct Rescaling {
        let priority: Int
        let patterns: [UInt64]
    }

    /// Visits the primitive tuple, scales two through four, up to eight successive halvings of the current scale, and its three nearest smaller scales. A checkpoint still has one shared probe budget, and each group has at most 15 distinct proposals.
    static func rescalings(for leaves: [ReductionLeaf]) -> [Rescaling] {
        guard let normalization = normalize(leaves) else { return [] }
        var scales: [UInt64] = [1, 2, 3, 4]
        var geometric = normalization.divisor
        for _ in 0 ..< maximumGeometricSteps {
            geometric /= 2
            scales.append(geometric)
        }
        for decrement in UInt64(1) ... 3 {
            scales.append(normalization.divisor > decrement ? normalization.divisor - decrement : 0)
        }
        var seen: Set<UInt64> = []
        return scales.enumerated().compactMap { priority, scale in
            guard scale > 0, scale < normalization.divisor, seen.insert(scale).inserted,
                  let patterns = normalization.patterns(scale: scale, leaves: leaves)
            else { return nil }
            return Rescaling(priority: priority, patterns: patterns)
        }
    }

    /// Divides semantic magnitudes by their greatest common divisor, preserving signs and zero. Rejects a trivial divisor, a non-improving source, or any result outside its leaf's domain rather than clamping away the common scale.
    static func patterns(for leaves: [ReductionLeaf]) -> [UInt64]? {
        normalize(leaves)?.patterns(scale: 1, leaves: leaves)
    }

    /// Separates semantic magnitudes from signed encodings so even `Int64.min` can be normalized without taking a signed absolute value.
    private struct Normalization {
        let divisor: UInt64
        let primitiveMagnitudes: [UInt64]

        /// Reconstructs signs from the original choices and rejects any scale that would leave a declared domain.
        func patterns(scale: UInt64, leaves: [ReductionLeaf]) -> [UInt64]? {
            var patterns: [UInt64] = []
            for index in leaves.indices {
                let leaf = leaves[index]
                let zero = leaf.choice.tag.simplestBitPattern
                // scale is smaller than the original divisor, so the magnitude and its signed encoding cannot overflow.
                let magnitude = primitiveMagnitudes[index] * scale
                let pattern = leaf.choice.bitPattern64 >= zero ? zero + magnitude : zero - magnitude
                guard leaf.range.contains(pattern) else { return nil }
                patterns.append(pattern)
            }
            guard ChoiceValue(patterns[0], tag: leaves[0].choice.tag).shortlexKey < leaves[0].choice.shortlexKey else { return nil }
            return patterns
        }
    }

    /// Computes the shared integer scale once; individual proposals enforce domain admission independently so an excluded primitive tuple does not discard viable larger scales.
    private static func normalize(_ leaves: [ReductionLeaf]) -> Normalization? {
        guard (2 ... 4).contains(leaves.count), leaves.allSatisfy({ leaf in
            switch leaf.choice.tag {
                case .int, .int8, .int16, .int32, .int64, .uint, .uint8, .uint16, .uint32, .uint64:
                    true
                default:
                    false
            }
        }) else { return nil }
        let magnitudes = leaves.map { leaf in
            let zero = leaf.choice.tag.simplestBitPattern
            let pattern = leaf.choice.bitPattern64
            return pattern >= zero ? pattern - zero : zero - pattern
        }
        let divisor = magnitudes.reduce(0, ReductionIntegerMath.greatestCommonDivisor)
        guard divisor > 1 else { return nil }
        return Normalization(divisor: divisor, primitiveMagnitudes: magnitudes.map { $0 / divisor })
    }
}
