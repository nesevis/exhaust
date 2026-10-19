extension FloatReduction {
    /// Tries simple boundaries and both adjacent representations for fractional leaves because rounding to a boundary can erase a floating-point failure.
    ///
    /// Fractional grids extend to the leaf's precision. Scaling through the significand keeps subnormal inputs usable without constructing an overflowing reciprocal. Neighbors use the leaf's order-preserving encoding, so a `Float` or half-precision probe moves by its own ULP rather than a `Double` ULP that disappears on conversion. Integral leaves stay with the integer search; perturbing them would introduce a fraction rather than remove one.
    static func precisionCandidates(for value: Double, tag: TypeTag) -> [UInt64] {
        guard value.isFinite, value.rounded(.towardZero) != value else {
            return []
        }
        let precision: Int
        let minimumExponent: Int
        switch tag {
            case .double:
                precision = 52
                minimumExponent = -1074
            case .float:
                precision = 23
                minimumExponent = -149
            case .float16:
                precision = 10
                minimumExponent = -24
            default:
                return []
        }

        var seen: Set<UInt64> = []
        var candidates: [UInt64] = []

        /// Converts before stepping so adjacency follows the leaf's storage width. Finite encodings leave room for both neighboring bit patterns.
        func appendBoundary(_ boundary: Double) {
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

        for boundary in [1.0, -1.0, 0.0, -0.0] {
            appendBoundary(boundary)
        }

        let lastExponent = max(minimumExponent, value.exponent - precision)
        for exponent in stride(from: 0, through: lastExponent, by: -1) {
            let scaled = Double(sign: value.sign, exponent: value.exponent - exponent, significand: value.significand)
            for rounded in [scaled.rounded(.down), scaled.rounded(.up)] {
                appendBoundary(Double(sign: .plus, exponent: exponent, significand: rounded))
            }
        }
        return candidates
    }
}
