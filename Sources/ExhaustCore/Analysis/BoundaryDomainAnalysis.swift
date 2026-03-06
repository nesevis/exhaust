//
//  BoundaryDomainAnalysis.swift
//  Exhaust
//

/// A parameter in the boundary model with synthetic values derived from
/// boundary value analysis of the underlying generator operation.
@_spi(ExhaustInternal) public struct BoundaryParameter: @unchecked Sendable {
    @_spi(ExhaustInternal) public let index: Int
    @_spi(ExhaustInternal) public let values: [UInt64]
    @_spi(ExhaustInternal) public let domainSize: UInt64
    @_spi(ExhaustInternal) public let kind: BoundaryParameterKind
}

@_spi(ExhaustInternal) public enum BoundaryParameterKind: @unchecked Sendable {
    /// A chooseBits with a range too large for finite-domain analysis.
    /// Values are boundary representatives: {min, min+1, midpoint, max-1, max, 0 if in range}
    case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)

    /// A sequence length, capped at 2 for the boundary model.
    /// Values are: {0, 1, 2} (or subset if range is smaller)
    case sequenceLength(lengthRange: ClosedRange<UInt64>)

    /// An element within a boundary-modeled sequence.
    /// Same boundary values as chooseBits for the element generator.
    case sequenceElement(elementIndex: Int, range: ClosedRange<UInt64>, tag: TypeTag)

    /// A pick between branches (same as finite-domain pick).
    case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)

    /// A chooseBits that was already small enough for finite-domain, kept as-is.
    case finiteChooseBits(range: ClosedRange<UInt64>, tag: TypeTag)
}

/// Result of boundary analysis — a synthetic finite domain suitable for IPOG.
@_spi(ExhaustInternal) public struct BoundaryDomainProfile: @unchecked Sendable {
    @_spi(ExhaustInternal) public let parameters: [BoundaryParameter]
}

// MARK: - Boundary Value Computation

/// Boundary value selection functions used by `ChoiceTreeAnalysis`.
@_spi(ExhaustInternal) public enum BoundaryDomainAnalysis {

    static func computeBoundaryValues(min: UInt64, max: UInt64, tag: TypeTag) -> [UInt64] {
        switch tag {
        case .double, .float:
            return computeFloatBoundaryValues(min: min, max: max, tag: tag)
        default:
            return computeIntegerBoundaryValues(min: min, max: max, tag: tag)
        }
    }

    private static func computeIntegerBoundaryValues(min: UInt64, max: UInt64, tag: TypeTag) -> [UInt64] {
        var values: Set<UInt64> = [min, max]
        if min < max { values.insert(min + 1) }
        if max > min { values.insert(max - 1) }
        values.insert(min + (max - min) / 2)

        if let zero = zeroBitPatternFor(tag: tag), zero >= min, zero <= max {
            values.insert(zero)
        }

        return values.sorted()
    }

    private static func computeFloatBoundaryValues(min: UInt64, max: UInt64, tag: TypeTag) -> [UInt64] {
        // For float types, check if range is the full type range
        let isFullRange: Bool
        switch tag {
        case .double:
            isFullRange = min == UInt64.min && max == UInt64.max
        case .float:
            isFullRange = min == UInt64(UInt32.min) && max == UInt64(UInt32.max)
        default:
            isFullRange = false
        }

        if isFullRange {
            return fullRangeFloatBoundaryValues(tag: tag)
        } else {
            return computeIntegerBoundaryValues(min: min, max: max, tag: tag)
        }
    }

    private static func fullRangeFloatBoundaryValues(tag: TypeTag) -> [UInt64] {
        var values = Set<UInt64>()
        switch tag {
        case .double:
            for c: Double in [
                -Double.greatestFiniteMagnitude, -1.0, -Double.leastNonzeroMagnitude,
                -0.0, 0.0, Double.leastNonzeroMagnitude,
                1.0, Double.greatestFiniteMagnitude,
                Double.nan, Double.infinity, -Double.infinity,
            ] {
                values.insert(c.bitPattern64)
            }
        case .float:
            for c: Float in [
                -Float.greatestFiniteMagnitude, -1.0, -Float.leastNonzeroMagnitude,
                -0.0, 0.0, Float.leastNonzeroMagnitude,
                1.0, Float.greatestFiniteMagnitude,
                Float.nan, Float.infinity, -Float.infinity,
            ] {
                values.insert(c.bitPattern64)
            }
        default:
            break
        }
        return values.sorted()
    }

    /// Returns the bit pattern for zero for the given type, if zero is a meaningful value.
    private static func zeroBitPatternFor(tag: TypeTag) -> UInt64? {
        switch tag {
        case .uint, .uint64, .uint32, .uint16, .uint8:
            return 0
        case .int:
            return Int(0).bitPattern64
        case .int64:
            return Int64(0).bitPattern64
        case .int32:
            return Int32(0).bitPattern64
        case .int16:
            return Int16(0).bitPattern64
        case .int8:
            return Int8(0).bitPattern64
        case .double:
            return Double(0.0).bitPattern64
        case .float:
            return Float(0.0).bitPattern64
        }
    }
}
