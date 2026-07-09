// SCA pipeline: domain construction for sequence covering arrays.
//
// Analyzes pick branches to build a domain profile suitable for covering array generation. Parameter-free branches contribute one domain value each; branches with analyzable arguments contribute the product of their parameter domain sizes. Gracefully degrades to command-type-only orderings when all branches are parameter-free.

/// Result of SCA domain construction — carries everything needed for covering array generation and tree replay.
///
/// Bundles the enumerable domain profile, optional argument mapping, and strength cap so the caller does not need to thread these values separately.
/// Lane configuration for spec-test SCA coverage.
///
/// When present, each domain value encodes `branchIndex * laneCount + laneValue`, and the tree builder emits a `.laneControl` chooseBits node alongside the pick selection.
package struct SCALaneConfig {
    /// Number of lane values (concurrency level + 1, including the prefix lane 0).
    public let laneCount: Int
    /// The pick choices, carried for branch metadata during tree construction.
    public let pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>
}

package struct SCADomain {
    /// The enumerable domain profile for covering array generation.
    public let profile: EnumerableDomainProfile
    /// Argument mapping for decomposing flat domain indices back to branch + argument values. Nil when all branches are parameter-free.
    public let mapping: SCADomainMapping?
    /// Lane configuration for spec-test coverage. Nil for property-test coverage.
    public let laneConfig: SCALaneConfig?
    /// Upper bound on interaction strength for covering array generation.
    public let maxStrength: Int

    /// Converts a covering array row into a ``ChoiceTree`` suitable for replay.
    ///
    /// Dispatches to the appropriate ``SequenceCoveringArray`` overload based on whether an argument mapping or lane configuration is present.
    public func buildTree(
        row: CoveringArrayRow,
        sequenceLengthRange: ClosedRange<UInt64>
    ) -> ChoiceTree? {
        if let laneConfig {
            SequenceCoveringArray.buildTreeWithLanes(
                row: row,
                profile: profile,
                laneConfig: laneConfig,
                sequenceLengthRange: sequenceLengthRange
            )
        } else if let mapping {
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
    /// Builds an SCA domain from pick choices and sequence metadata.
    ///
    /// - Parameters:
    ///   - sequenceLength: Number of positions in each test sequence.
    ///   - pickChoices: The command types available at each position.
    ///   - coverageBudget: The covering array row budget, used for threshold computation.
    ///   - strengthCap: Upper bound on interaction strength derived from sequence length.
    ///   - commandTypeOnly: When `true`, skips argument analysis and treats every branch as parameter-free. The domain per position equals the branch count, covering command-type orderings without argument interactions. Use for spec tests where command-type diversity matters more than argument value coverage.
    public static func build(
        sequenceLength: Int,
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        coverageBudget: UInt64,
        strengthCap: Int,
        commandTypeOnly: Bool = false
    ) -> SCADomain? {
        let branchProfiles: [BranchArgProfile]
        if commandTypeOnly {
            branchProfiles = pickChoices.map { _ in .parameterFree }
        } else {
            let threshold = SequenceCoveringArray.computeThreshold(
                budget: coverageBudget,
                sequenceLength: sequenceLength,
                branchCount: pickChoices.count
            )
            branchProfiles = SequenceCoveringArray.analyzeBranches(
                pickChoices,
                threshold: threshold,
                coverageBudget: coverageBudget
            )
        }
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
        return SCADomain(profile: profile, mapping: mapping, laneConfig: nil, maxStrength: maxStrength)
    }

    /// Builds an SCA domain for spec tests that covers command-type × lane-assignment combinations.
    ///
    /// Each position's domain is `branchCount × laneCount`, where `laneCount` is `concurrencyLevel + 1` (lane 0 is the sequential prefix). The covering array systematically pairs every command type with every lane assignment at every position, ensuring diverse command-lane combinations appear in early rows.
    public static func buildForStateMachine(
        sequenceLength: Int,
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        concurrencyLevel: Int,
        strengthCap: Int
    ) -> SCADomain {
        let laneCount = concurrencyLevel + 1
        let domainSize = UInt64(pickChoices.count) * UInt64(laneCount)

        let parameters = (0 ..< sequenceLength).map { index in
            EnumerableParameter(
                index: index,
                domainSize: domainSize,
                kind: .pick(choices: pickChoices)
            )
        }

        let totalSpace = parameters.reduce(UInt64(1)) { accumulator, param in
            let (product, overflow) = accumulator.multipliedReportingOverflow(by: param.domainSize)
            return overflow ? .max : product
        }
        let profile = EnumerableDomainProfile(parameters: parameters, totalSpace: totalSpace)
        let laneConfig = SCALaneConfig(laneCount: laneCount, pickChoices: pickChoices)

        return SCADomain(profile: profile, mapping: nil, laneConfig: laneConfig, maxStrength: min(2, strengthCap))
    }
}
