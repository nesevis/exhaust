// SCA pipeline: domain construction for sequence covering arrays.
//
// Analyzes pick branches to build a domain profile suitable for covering array generation. Parameter-free branches contribute one domain value each; branches with analyzable arguments contribute the product of their parameter domain sizes. Gracefully degrades to command-type-only orderings when all branches are parameter-free.

/// Result of SCA domain construction — carries everything needed for covering array generation and tree replay.
///
/// Bundles the finite domain profile, optional argument mapping, and strength cap so the caller does not need to thread these values separately.
public struct SCADomain {
    /// The finite domain profile for covering array generation.
    public let profile: FiniteDomainProfile
    /// Argument mapping for decomposing flat domain indices back to branch + argument values. Nil when all branches are parameter-free.
    public let mapping: SCADomainMapping?
    /// Upper bound on interaction strength for covering array generation.
    public let maxStrength: Int

    /// Converts a covering array row into a ``ChoiceTree`` suitable for replay.
    ///
    /// Dispatches to the appropriate ``SequenceCoveringArray`` overload based on whether an argument mapping is present, eliminating the `if let mapping` dispatch at call sites.
    public func buildTree(
        row: CoveringArrayRow,
        sequenceLengthRange: ClosedRange<UInt64>
    ) -> ChoiceTree? {
        if let mapping {
            SequenceCoveringArray.buildTree(
                row: row,
                profile: profile,
                mapping: mapping,
                sequenceLengthRange: sequenceLengthRange
            )
        } else {
            SequenceCoveringArray.buildTree(
                row: row,
                profile: profile,
                sequenceLengthRange: sequenceLengthRange
            )
        }
    }

    /// Builds an SCA domain from pick choices and sequence metadata.
    ///
    /// Each position's domain is the sum of all branch contributions: parameter-free branches contribute 1, analyzed branches contribute the product of their parameter domain sizes, and unanalyzable branches contribute 1 (random arguments at replay). Caps interaction strength at t=2 when any branch has analyzed arguments to keep covering array sizes manageable.
    ///
    /// - Parameters:
    ///   - sequenceLength: Number of positions in each test sequence.
    ///   - pickChoices: The command types available at each position.
    ///   - coverageBudget: The covering array row budget, used for threshold computation.
    ///   - strengthCap: Upper bound on interaction strength derived from sequence length.
    /// - Returns: An ``SCADomain`` ready for covering array construction, or nil if no branches can be analyzed.
    public static func build(
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
        let branchProfiles = SequenceCoveringArray.analyzeBranches(
            pickChoices,
            threshold: threshold
        )
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
