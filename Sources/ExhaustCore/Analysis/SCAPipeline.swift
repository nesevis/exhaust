// SCA pipeline decomposition: composable stages for sequence covering array construction.
//
// Breaks the monolithic SequenceCoveringArray call pattern into a protocol-based pipeline
// where domain construction is interchangeable. The two existing paths (command-type-only
// and argument-aware) become concrete conformers of SCADomainBuilder.

/// Result of SCA domain construction — carries everything needed for covering array generation and tree replay.
///
/// Bundles the finite domain profile, optional argument mapping, and strength cap so the caller does not need to thread these values separately.
public struct SCADomain {
    /// The finite domain profile for IPOG.
    public let profile: FiniteDomainProfile
    /// Argument mapping for decomposing flat domain indices back to branch + argument values. Nil for command-type-only domains.
    public let mapping: SCADomainMapping?
    /// Upper bound on interaction strength for ``CoveringArray/bestFitting(budget:profile:maxStrength:)``.
    public let maxStrength: Int

    /// Converts a covering array row into a ``ChoiceTree`` suitable for replay.
    ///
    /// Dispatches to the appropriate ``SequenceCoveringArray`` overload based on whether an argument mapping is present, eliminating the `if let mapping` dispatch at call sites.
    public func buildTree(row: CoveringArrayRow, sequenceLengthRange: ClosedRange<UInt64>) -> ChoiceTree? {
        if let mapping {
            SequenceCoveringArray.buildTree(row: row, profile: profile, mapping: mapping, sequenceLengthRange: sequenceLengthRange)
        } else {
            SequenceCoveringArray.buildTree(row: row, profile: profile, sequenceLengthRange: sequenceLengthRange)
        }
    }
}

/// A stage in the SCA construction pipeline that builds a domain profile from pick choices.
///
/// Each conformer represents a different analysis strategy for SCA domains. ``CommandTypeSCABuilder`` produces simple command-type orderings; ``ArgumentAwareSCABuilder`` flattens branch argument domains for pairwise argument coverage. The pipeline consumer (``ContractRunner``) selects the appropriate builder based on settings and delegates all domain-specific logic to it.
public protocol SCADomainBuilder {
    /// Builds an SCA domain from pick choices and sequence metadata.
    ///
    /// - Parameters:
    ///   - sequenceLength: Number of positions in each test sequence.
    ///   - pickChoices: The command types available at each position.
    ///   - coverageBudget: The covering array row budget, used for threshold computation in argument-aware builders.
    ///   - strengthCap: Upper bound on interaction strength derived from sequence length.
    /// - Returns: An ``SCADomain`` ready for covering array construction, or nil if the builder's preconditions are not met.
    func buildDomain(
        sequenceLength: Int,
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        coverageBudget: UInt64,
        strengthCap: Int
    ) -> SCADomain?
}

// MARK: - Concrete Builders

/// Command-type-only SCA domain builder — each position's domain is the set of command types.
///
/// Requires all branches to be parameter-free (no choices in sub-generators). Produces `.just("")` sub-trees, which cannot satisfy parameterized branches during replay.
public struct CommandTypeSCABuilder: SCADomainBuilder {
    public init() {}

    public func buildDomain(
        sequenceLength: Int,
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        coverageBudget: UInt64,
        strengthCap: Int
    ) -> SCADomain? {
        guard SequenceCoveringArray.allBranchesParameterFree(pickChoices) else { return nil }
        let profile = SequenceCoveringArray.buildProfile(
            sequenceLength: sequenceLength,
            pickChoices: pickChoices
        )
        return SCADomain(profile: profile, mapping: nil, maxStrength: strengthCap)
    }
}

/// Argument-aware SCA domain builder — flattens branch argument domains via threshold normalization.
///
/// Each position's domain is the sum of all branch contributions: parameter-free branches contribute 1, analyzed branches contribute the product of their parameter domain sizes, and unanalyzable branches contribute 1 (random arguments at replay). Caps interaction strength at t=2 when any branch has analyzed arguments to avoid combinatorially expensive IPOG runs.
public struct ArgumentAwareSCABuilder: SCADomainBuilder {
    public init() {}

    public func buildDomain(
        sequenceLength: Int,
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        coverageBudget: UInt64,
        strengthCap: Int
    ) -> SCADomain? {
        let threshold = SequenceCoveringArray.computeThreshold(
            budget: coverageBudget,
            sequenceLength: sequenceLength,
            branchCount: pickChoices.count
        )
        let branchProfiles = SequenceCoveringArray.analyzeBranches(pickChoices, threshold: threshold)
        let (profile, mapping) = SequenceCoveringArray.buildProfile(
            sequenceLength: sequenceLength,
            pickChoices: pickChoices,
            branchProfiles: branchProfiles
        )
        let hasArgumentDomains = branchProfiles.contains {
            if case .analyzed = $0 { return true }
            return false
        }
        let maxStrength = hasArgumentDomains ? min(2, strengthCap) : strengthCap
        return SCADomain(profile: profile, mapping: mapping, maxStrength: maxStrength)
    }
}
