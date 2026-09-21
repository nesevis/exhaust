//
//  EnumerableDomainProfile.swift
//  Exhaust
//

/// A single factor in the combinatorial model.
package struct EnumerableParameter: @unchecked Sendable {
    // @unchecked Sendable: the `.pick` case stores `ContiguousArray<ReflectiveOperation.PickTuple>`, which contains generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// Distinguishes the two generator operations that produce enumerable parameters, so the screening runner can replay values through the correct interpretation path.
    public enum Kind {
        /// Represents a range-bounded bit-pattern choice whose domain is small enough for exhaustive enumeration.
        case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)
        /// Represents a weighted branch selection among a fixed set of alternatives.
        case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)
    }

    /// Zero-based parameter index in the covering array model.
    public let index: Int
    /// Number of distinct values in this parameter's domain.
    public let domainSize: UInt64
    /// The generator operation this parameter was derived from.
    public let kind: Kind
}

/// Result of analyzing a generator for enumerable structure.
package struct EnumerableDomainProfile: @unchecked Sendable {
    // @unchecked Sendable: stores `[EnumerableParameter]` and `ChoiceTree?`. `ChoiceTree` nodes contain generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// The enumerable parameters extracted from the generator's choice tree.
    public let parameters: [EnumerableParameter]
    /// Product of all domainSizes. Capped at UInt64.max on overflow.
    public let totalSpace: UInt64
    /// The tree VACTI produced, paired with whether it witnessed the whole domain.
    public let template: AnalysisTemplate?

    /// Creates a profile with the given parameters, precomputed total space, and optional template.
    public init(parameters: [EnumerableParameter], totalSpace: UInt64, template: AnalysisTemplate? = nil) {
        self.parameters = parameters
        self.totalSpace = totalSpace
        self.template = template
    }
}

/// The ChoiceTree screening rebuilds rows from, carrying whether the run that produced it saw the whole domain.
///
/// The tree is a template rather than a trace: screening analysis records only the pick arm it selected, so a question about the whole domain cannot be answered by walking it. ``isTotalWitness`` is the answer to that question, decided where the elision happened. The tree is reachable only as ``substitutionTemplate``, which names the one job it is complete enough for.
package struct AnalysisTemplate: @unchecked Sendable {
    // @unchecked Sendable: `ChoiceTree` nodes contain generator closures the compiler cannot verify as Sendable. All closures are framework-controlled and do not capture shared mutable state.

    /// Positional template for ``CoveringArrayReplay``, which substitutes parameter values at matching positions and preserves structural nodes.
    public let substitutionTemplate: ChoiceTree

    /// Whether every choice the generator can make is accounted for by the extracted parameters. False when a pick arm or a preserved node holds a choice, when analysis skipped an arm that draws, or when the tree itself binds.
    public let isTotalWitness: Bool

    /// Creates a template and records whether it witnessed the whole domain.
    public init(substitutionTemplate: ChoiceTree, isTotalWitness: Bool) {
        self.substitutionTemplate = substitutionTemplate
        self.isTotalWitness = isTotalWitness
    }
}

extension EnumerableDomainProfile: ScreeningProfile {
    public var domainSizes: [UInt64] {
        parameters.map { $0.domainSize }
    }

    public var parameterCount: Int {
        parameters.count
    }

    public func buildTree(from row: CoveringArrayRow) -> ChoiceTree? {
        CoveringArrayReplay.buildTree(row: row, profile: self)
    }
}
