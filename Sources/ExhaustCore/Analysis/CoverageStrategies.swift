// Concrete CoverageStrategy conformers wrapping existing covering array construction logic.
//
// Each strategy encapsulates the budget checks and CoveringArray API calls that were
// previously inline in CoverageRunner.runFinite / runBoundary.

// MARK: - Finite Domain Strategies

/// Exhaustive enumeration — used when the total parameter space fits within the budget and the generator has no bind nodes.
///
/// Produces a covering array at strength = paramCount (every combination tested). Returns nil when the space exceeds the budget or when binds are present, since bind-bound subtrees vary per inner value and cannot be exhaustively covered.
public struct ExhaustiveCoverageStrategy: CoverageStrategy {
    public let name: CoverageStrategyName = .exhaustive
    public let phase: CoveragePhase = .exhaustive

    /// Whether the profile's original tree contains bind nodes.
    public let hasBinds: Bool

    public init(hasBinds: Bool) {
        self.hasBinds = hasBinds
    }

    public func estimatedRows(profile: FiniteDomainProfile, budget: UInt64) -> Int? {
        guard hasBinds == false, profile.totalSpace <= budget else { return nil }
        return Int(profile.totalSpace)
    }

    public func generate(profile: FiniteDomainProfile, budget: UInt64) -> CoveringArray? {
        guard hasBinds == false, profile.totalSpace <= budget else { return nil }
        return CoveringArray.generate(profile: profile, strength: profile.parameters.count)
    }
}

/// IPOG t-way coverage — searches for the strongest covering array that fits within the budget.
///
/// Wraps ``CoveringArray/bestFitting(budget:profile:maxStrength:)`` which tries strengths 2...maxStrength bottom-up.
public struct TWayCoverageStrategy: CoverageStrategy {
    public let name: CoverageStrategyName = .tWay
    public let phase: CoveragePhase = .tWay

    /// Upper bound on interaction strength. Defaults to 6.
    public let maxStrength: Int

    public init(maxStrength: Int = 6) {
        self.maxStrength = maxStrength
    }

    public func estimatedRows(profile: FiniteDomainProfile, budget: UInt64) -> Int? {
        guard profile.parameters.count >= 2 else { return nil }
        // Cannot cheaply estimate without running IPOG, so defer to generate.
        return 0
    }

    public func generate(profile: FiniteDomainProfile, budget: UInt64) -> CoveringArray? {
        CoveringArray.bestFitting(budget: budget, profile: profile, maxStrength: maxStrength)
    }
}

/// Single-parameter fallback — strength-1 covering that tests each value for the sole parameter.
///
/// ``CoveringArray/bestFitting(budget:profile:maxStrength:)`` requires at least 2 parameters. This strategy handles the single-parameter edge case by generating a strength-1 covering array directly.
public struct SingleParameterCoverageStrategy: CoverageStrategy {
    public let name: CoverageStrategyName = .singleParameter
    public let phase: CoveragePhase = .tWay

    public init() {}

    public func estimatedRows(profile: FiniteDomainProfile, budget: UInt64) -> Int? {
        guard profile.parameters.count == 1 else { return nil }
        let domainSize = profile.parameters[0].domainSize
        guard domainSize <= budget else { return nil }
        return Int(domainSize)
    }

    public func generate(profile: FiniteDomainProfile, budget: UInt64) -> CoveringArray? {
        guard profile.parameters.count == 1 else { return nil }
        return CoveringArray.generate(profile: profile, strength: 1)
    }
}

// MARK: - Boundary Domain Strategy

/// Boundary-value coverage for profiles with large-domain parameters.
///
/// For profiles with a single sequence parameter group, partitions rows by sequence length
/// so each sub-array only contains element parameters accessible at that length. This avoids
/// the flat IPOG bug where element values are assigned to `sequenceLength=0` rows that produce
/// empty arrays. Falls back to flat IPOG for profiles without sequences or with multiple sequences.
public struct BoundaryValueCoverageStrategy: BoundaryCoverageStrategy {
    public let name: CoverageStrategyName = .boundary
    public let phase: CoveragePhase = .boundary

    public init() {}

    public func estimatedRows(profile: BoundaryDomainProfile, budget: UInt64) -> Int? {
        // Cannot cheaply estimate without running IPOG, so defer to generate.
        0
    }

    public func generate(profile: BoundaryDomainProfile, budget: UInt64) -> BoundaryCoverageResult? {
        // Try per-length partitioned construction for single-sequence profiles.
        if let subArrays = CoveringArray.bestFittingPerLength(budget: budget, boundaryProfile: profile) {
            return .perLength(subArrays: subArrays)
        }

        // Fall back to flat IPOG for non-sequence or multi-sequence profiles.
        guard let covering = CoveringArray.bestFitting(budget: budget, boundaryProfile: profile) else {
            return nil
        }
        return .flat(covering)
    }
}
