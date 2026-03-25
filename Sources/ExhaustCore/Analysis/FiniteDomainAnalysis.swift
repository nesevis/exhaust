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
    /// The original ChoiceTree from VACTI, used as a template for covering array replay.
    /// When present, `CoveringArrayReplay.buildTree` walks this tree and substitutes
    /// parameter values at matching positions, preserving structural nodes like `.bind`.
    public let originalTree: ChoiceTree?

    public init(parameters: [FiniteParameter], totalSpace: UInt64, originalTree: ChoiceTree? = nil) {
        self.parameters = parameters
        self.totalSpace = totalSpace
        self.originalTree = originalTree
    }
}

extension FiniteDomainProfile: CoverageProfile {
    public var domainSizes: [UInt64] {
        parameters.map(\.domainSize)
    }

    public var parameterCount: Int {
        parameters.count
    }

    public func buildTree(from row: CoveringArrayRow) -> ChoiceTree? {
        CoveringArrayReplay.buildTree(row: row, profile: self)
    }
}
