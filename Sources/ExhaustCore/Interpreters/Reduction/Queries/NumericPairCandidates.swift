/// Proposes bit patterns for one side of a numeric pair: the reduction target, local neighbors, range boundaries, power-of-two scales, and successive interval midpoints.
///
/// Search coordinates stay separate from numeric arithmetic: integer offsets are exact, while float proposals use semantic values and representable neighbors.
enum NumericPairCandidates {
    static let maximumSamples = 64

    /// Samples the target, local changes, boundaries, and successively subdivided intervals without assuming a monotone property.
    static func values(for leaf: NumericPairQuery.Leaf, simplifying: Bool) -> [UInt64] {
        let current = leaf.choice.bitPattern64
        let target = leaf.choice.reductionTarget(in: leaf.range)
        var candidates: [UInt64] = []
        var visited: Set<UInt64> = []
        func append(_ pattern: UInt64) {
            guard candidates.count < maximumSamples,
                  pattern != current,
                  leaf.range.contains(pattern),
                  visited.insert(pattern).inserted
            else {
                return
            }
            let value = ChoiceValue(pattern, tag: leaf.choice.tag)
            guard leaf.choice.tag.isFloatingPoint == false || value.decodedDoubleValue.isFinite,
                  simplifying == false || value.shortlexKey < leaf.choice.shortlexKey
                  || (value.shortlexKey == leaf.choice.shortlexKey && pattern < current)
            else {
                return
            }
            candidates.append(pattern)
        }
        append(target)
        for delta: UInt64 in [1, 2, 4] {
            let (raised, overflow) = current.addingReportingOverflow(delta)
            if overflow == false {
                append(raised)
            }
            if current >= delta {
                append(current - delta)
            }
        }
        append(leaf.range.lowerBound)
        append(leaf.range.upperBound)
        if leaf.choice.tag.isFloatingPoint {
            let value = leaf.choice.decodedDoubleValue
            for delta in [1.0, 2.0, 4.0] {
                append(leaf.choice.tag.floatingBitPattern(from: value + delta))
                append(leaf.choice.tag.floatingBitPattern(from: value - delta))
            }
            let truncated = value.rounded(.towardZero)
            for exponent in -8 ... 8 {
                let scale = Double(sign: .plus, exponent: exponent, significand: 1)
                for proposal in [scale, -scale, value * scale, truncated] where proposal.isFinite {
                    append(leaf.choice.tag.floatingBitPattern(from: proposal))
                }
            }
        } else {
            let zero = leaf.choice.tag.simplestBitPattern
            for exponent in 0 ..< 8 {
                for magnitude in [(UInt64(1) << exponent) - 1, UInt64(1) << exponent] {
                    let (positive, overflow) = zero.addingReportingOverflow(magnitude)
                    if overflow == false {
                        append(positive)
                    }
                    if leaf.choice.tag.isSigned, zero >= magnitude {
                        append(zero - magnitude)
                    }
                }
            }
        }
        // The encoding is ordered by semantic value, including floats. Subdivision fills representable gaps without treating their encodings as arithmetic magnitudes.
        let interval = simplifying ? min(current, target) ... max(current, target) : leaf.range
        var intervals = [interval]
        var intervalIndex = 0
        while intervalIndex < intervals.count, intervalIndex < maximumSamples * 4, candidates.count < maximumSamples {
            let range = intervals[intervalIndex]
            intervalIndex += 1
            let middle = range.lowerBound + (range.upperBound - range.lowerBound) / 2
            append(middle)
            if middle > range.lowerBound {
                intervals.append(range.lowerBound ... middle - 1)
            }
            if middle < range.upperBound {
                intervals.append(middle + 1 ... range.upperBound)
            }
        }
        return candidates
    }
}
