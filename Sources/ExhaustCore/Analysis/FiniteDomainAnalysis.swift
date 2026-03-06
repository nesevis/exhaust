//
//  FiniteDomainAnalysis.swift
//  Exhaust
//

/// A single factor in the combinatorial model.
public struct FiniteParameter: @unchecked Sendable {
    /// The type of generator operation this parameter came from.
    public enum Kind {
        case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)
        case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)
    }

    public let index: Int
    public let domainSize: UInt64
    public let kind: Kind
}

/// Result of analyzing a generator for finite-domain structure.
public struct FiniteDomainProfile: @unchecked Sendable {
    public let parameters: [FiniteParameter]
    /// Product of all domainSizes. Capped at UInt64.max on overflow.
    public let totalSpace: UInt64
}
