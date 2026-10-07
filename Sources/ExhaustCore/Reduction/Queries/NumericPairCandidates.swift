/// Proposes bit patterns for one side of a numeric pair: the reduction target, local neighbors, range boundaries, power-of-two scales, and successive interval midpoints.
///
/// Search coordinates stay separate from numeric arithmetic: integer offsets are exact, while float proposals use semantic values and representable neighbors.
enum NumericPairCandidates {
    static let maximumSamples = 64

    /// Samples the target, local changes, boundaries, and successively subdivided intervals without assuming a monotone property.
    ///
    /// Proposal order matters: it decides which candidates fit under ``maximumSamples`` and the order the pair cursor probes them in.
    static func values(for leaf: NumericPairQuery.Leaf, simplifying: Bool) -> [UInt64] {
        var samples = CandidateSamples(leaf: leaf, simplifying: simplifying)
        samples.append(samples.target)
        samples.appendNeighbors()
        samples.appendBoundaries()
        if leaf.choice.tag.isFloatingPoint {
            samples.appendFloatingProposals()
        } else {
            samples.appendIntegerMagnitudes()
        }
        samples.appendSubdivisions()
        return samples.candidates
    }

    /// Keeps higher-order grids small while trying targets, coherent halving, local compensation, and simple magnitudes before widening. These are proposals, not an exhaustive domain or a monotonicity assumption.
    static func jointValues(for leaf: NumericPairQuery.Leaf, simplifying: Bool) -> [UInt64] {
        var samples = CandidateSamples(leaf: leaf, simplifying: simplifying)
        samples.append(samples.target)
        let zero = leaf.choice.tag.simplestBitPattern
        let current = leaf.choice.bitPattern64
        let half = current >= zero ? zero + (current - zero) / 2 : zero - (zero - current) / 2
        samples.append(half)
        let lower = min(current, samples.target)
        let upper = max(current, samples.target)
        samples.append(lower + (upper - lower) / 2)
        for magnitude: UInt64 in [1, 2, 3] {
            let (positive, overflow) = zero.addingReportingOverflow(magnitude)
            if overflow == false { samples.append(positive) }
            if leaf.choice.tag.isSigned, zero >= magnitude { samples.append(zero - magnitude) }
        }
        samples.appendNeighbors()
        samples.appendIntegerMagnitudes()
        return Array(samples.candidates.prefix(6))
    }
}

// MARK: - Candidate Samples

/// Collects distinct admissible bit patterns in proposal order, up to ``NumericPairCandidates/maximumSamples``.
private struct CandidateSamples {
    let leaf: NumericPairQuery.Leaf
    let simplifying: Bool
    let current: UInt64
    let target: UInt64
    private(set) var candidates: [UInt64] = []
    private var visited: Set<UInt64> = []

    init(leaf: NumericPairQuery.Leaf, simplifying: Bool) {
        self.leaf = leaf
        self.simplifying = simplifying
        current = leaf.choice.bitPattern64
        target = leaf.choice.reductionTarget(in: leaf.range)
    }

    /// Records a pattern the first time it is proposed. A pattern that fails admission is still marked visited, so it is never reconsidered.
    mutating func append(_ pattern: UInt64) {
        guard candidates.count < NumericPairCandidates.maximumSamples,
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

    /// Bit-pattern steps of one, two, and four in each direction.
    mutating func appendNeighbors() {
        for delta: UInt64 in [1, 2, 4] {
            let (raised, overflow) = current.addingReportingOverflow(delta)
            if overflow == false {
                append(raised)
            }
            if current >= delta {
                append(current - delta)
            }
        }
    }

    mutating func appendBoundaries() {
        append(leaf.range.lowerBound)
        append(leaf.range.upperBound)
    }

    /// Semantic steps of one, two, and four, then signed powers of two, the current value scaled by them, and the current value truncated toward zero.
    mutating func appendFloatingProposals() {
        let tag = leaf.choice.tag
        let value = leaf.choice.decodedDoubleValue
        for delta in [1.0, 2.0, 4.0] {
            append(tag.floatingBitPattern(from: value + delta))
            append(tag.floatingBitPattern(from: value - delta))
        }
        let truncated = value.rounded(.towardZero)
        for exponent in -8 ... 8 {
            let scale = Double(sign: .plus, exponent: exponent, significand: 1)
            for proposal in [scale, -scale, value * scale, truncated] where proposal.isFinite {
                self.append(tag.floatingBitPattern(from: proposal))
            }
        }
    }

    /// Powers of two and their predecessors on each side of the simplest pattern.
    mutating func appendIntegerMagnitudes() {
        let tag = leaf.choice.tag
        let zero = tag.simplestBitPattern
        for exponent in 0 ..< 8 {
            for magnitude in [(UInt64(1) << exponent) - 1, UInt64(1) << exponent] {
                let (positive, overflow) = zero.addingReportingOverflow(magnitude)
                if overflow == false {
                    append(positive)
                }
                if tag.isSigned, zero >= magnitude {
                    append(zero - magnitude)
                }
            }
        }
    }

    /// Breadth-first midpoints of the interval toward the target, or of the whole range when not simplifying.
    ///
    /// The encoding is ordered by semantic value, including floats. Subdivision fills representable gaps without treating their encodings as arithmetic magnitudes.
    mutating func appendSubdivisions() {
        let interval = simplifying
            ? min(current, target) ... max(current, target)
            : leaf.range
        var intervals = [interval]
        var intervalIndex = 0
        while intervalIndex < intervals.count,
              intervalIndex < NumericPairCandidates.maximumSamples * 4,
              candidates.count < NumericPairCandidates.maximumSamples
        {
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
    }
}
