//
//  FiniteDomainAnalysis.swift
//  Exhaust
//

/// A single factor in the combinatorial model.
package struct FiniteParameter: @unchecked Sendable {
    // @unchecked Sendable: the `.pick` case stores `ContiguousArray<ReflectiveOperation.PickTuple>`, which contains generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// The type of generator operation this parameter came from.
    public enum Kind {
        case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)
        case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)
    }

    /// Zero-based parameter index in the covering array model.
    public let index: Int
    /// Number of distinct values in this parameter's domain.
    public let domainSize: UInt64
    /// The generator operation this parameter was derived from.
    public let kind: Kind
}

/// Result of analyzing a generator for finite-domain structure.
package struct FiniteDomainProfile: @unchecked Sendable {
    // @unchecked Sendable: stores `[FiniteParameter]` and `ChoiceTree?`. `ChoiceTree` nodes contain generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// The finite parameters extracted from the generator's choice tree.
    public let parameters: [FiniteParameter]
    /// Product of all domainSizes. Capped at UInt64.max on overflow.
    public let totalSpace: UInt64
    /// The original ChoiceTree from VACTI, used as a template for covering array replay. When present, `CoveringArrayReplay.buildTree` walks this tree and substitutes parameter values at matching positions, preserving structural nodes like `.bind`.
    public let originalTree: ChoiceTree?

    /// Creates a profile with the given parameters, precomputed total space, and optional original tree template.
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
