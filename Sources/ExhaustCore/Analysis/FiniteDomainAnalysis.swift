//
//  FiniteDomainAnalysis.swift
//  Exhaust
//

/// A single factor in the combinatorial model.
@_spi(ExhaustInternal) public struct FiniteParameter: @unchecked Sendable {
    /// The type of generator operation this parameter came from.
    @_spi(ExhaustInternal) public enum Kind {
        case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)
        case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)
    }

    @_spi(ExhaustInternal) public let index: Int
    @_spi(ExhaustInternal) public let domainSize: UInt64
    @_spi(ExhaustInternal) public let kind: Kind
}

/// Result of analyzing a generator for finite-domain structure.
@_spi(ExhaustInternal) public struct FiniteDomainProfile: @unchecked Sendable {
    @_spi(ExhaustInternal) public let parameters: [FiniteParameter]
    /// Product of all domainSizes. Capped at UInt64.max on overflow.
    @_spi(ExhaustInternal) public let totalSpace: UInt64
}
