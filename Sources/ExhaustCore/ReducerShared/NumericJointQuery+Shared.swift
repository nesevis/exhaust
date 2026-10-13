//
//  NumericJointQuery+Shared.swift
//  Exhaust
//

// MARK: - Numeric Joint Group

/// A ranked group of leaves for joint numeric search, as ``ExchangeScope/numericJoint(_:probeBudget:)`` carries it.
extension NumericJointQuery {
    /// Ranks compact descriptors rather than materialized candidate histories.
    struct Group {
        let leaves: [ReductionLeaf]
        let samples: [[UInt64]]
        let ratioProposals: [NumericCommonDivisorProposal.Rescaling]
        let estimatedWork: Int
        let residualVolume: UInt64
        let stalledCount: Int
        let couplingCount: Int
        let sharedContextCount: Int

        func precedes(_ other: Group) -> Bool {
            if couplingCount != other.couplingCount { return couplingCount > other.couplingCount }
            if stalledCount != other.stalledCount { return stalledCount > other.stalledCount }
            if sharedContextCount != other.sharedContextCount { return sharedContextCount > other.sharedContextCount }
            return residualVolume < other.residualVolume
        }
    }
}
