extension FloatReduction {
    /// Tries the simplest boundaries and both adjacent representations for fractional leaves because rounding to a boundary can erase a floating-point failure.
    ///
    /// Zero and its neighbors come before one and its neighbors, each positive sign before its negative, because the first accepted boundary ends the leaf's boundary stage. Integral leaves stay with the integer search; perturbing them would introduce a fraction rather than remove one.
    static func boundaryCandidates(for value: Double, tag: TypeTag) -> [UInt64] {
        guard tag.isFloatingPoint, finestGrid(of: value) != nil else {
            return []
        }
        var seen: Set<UInt64> = []
        var candidates: [UInt64] = []
        for boundary in [0.0, -0.0, 1.0, -1.0] {
            appendRepresentations(of: boundary, tag: tag, to: &candidates, seen: &seen)
        }
        return candidates
    }

    /// The finest binary grid a fractional value lies on: the value is a multiple of 2^-`grid` but not of 2^-(`grid` − 1). Nil for integral and non-finite values.
    ///
    /// Coarser grids are the only ones whose rounding changes the value, so a grid walk starts here. A value narrowed from `Float` or half precision has the same grid as its `Double` widening.
    static func finestGrid(of value: Double) -> Int? {
        guard value.isFinite, value.rounded(.towardZero) != value else {
            return nil
        }
        return value.significandWidth - Int(value.exponent)
    }

    /// Rounds `value` down and up to the grid 2^-`grid` and adds both adjacent representations of each, in shortlex order.
    ///
    /// Scaling through the significand keeps subnormal inputs usable without constructing an overflowing reciprocal.
    static func gridCandidates(for value: Double, grid: Int, tag: TypeTag) -> [UInt64] {
        let scaled = Double(sign: value.sign, exponent: value.exponent + grid, significand: value.significand)
        var seen: Set<UInt64> = []
        var candidates: [UInt64] = []
        for rounded in [scaled.rounded(.down), scaled.rounded(.up)] {
            appendRepresentations(
                of: Double(sign: .plus, exponent: -grid, significand: rounded),
                tag: tag,
                to: &candidates,
                seen: &seen
            )
        }
        return candidates.sorted {
            ChoiceValue($0, tag: tag).shortLexCompare(ChoiceValue($1, tag: tag)) == .lt
        }
    }

    /// Converts before stepping so adjacency follows the leaf's storage width: a `Float` or half-precision probe moves by its own ULP rather than a `Double` ULP that disappears on conversion. Finite encodings leave room for both neighboring bit patterns.
    private static func appendRepresentations(
        of boundary: Double,
        tag: TypeTag,
        to candidates: inout [UInt64],
        seen: inout Set<UInt64>
    ) {
        guard let choice = tag.floatingChoice(from: boundary) else {
            return
        }
        for bitPattern in [choice.bitPattern64, choice.bitPattern64 - 1, choice.bitPattern64 + 1] {
            let candidate = tag.numericDoubleValue(forBitPattern: bitPattern)
            guard candidate.isFinite,
                  seen.insert(bitPattern).inserted
            else {
                continue
            }
            candidates.append(bitPattern)
        }
    }
}
