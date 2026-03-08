// Sequence Covering Array (SCA) construction for state-machine property testing.
//
// An SCA guarantees every t-way ordered permutation of command types appears in
// at least one test sequence. Mathematically equivalent to a standard covering
// array where each parameter is a sequence position and each domain value is a
// command type. See Kuhn, Raunak & Kacker, "Ordered t-way Combinations for
// Testing State-based Systems".

/// Builds covering arrays over command-type orderings for state-machine testing.
///
/// Each position in the command sequence becomes a parameter whose domain is the
/// set of command types (pick branches). IPOG generates rows that guarantee every
/// t-way ordered permutation of command types is tested.
///
/// For `c` command types, sequence length `L`, strength `t`:
/// IPOG produces roughly `c^t × log(L)` rows.
/// - 5 commands, length 10, t=2: ~40–50 rows
/// - 10 commands, length 15, t=2: ~150–200 rows
public enum SequenceCoveringArray {
    /// Builds a `FiniteDomainProfile` where each parameter represents one position
    /// in the command sequence, with domain values being command type indices.
    ///
    /// - Parameters:
    ///   - sequenceLength: Number of positions in each test sequence.
    ///   - pickChoices: The command types available at each position (from `Gen.pick`).
    /// - Returns: A profile suitable for `CoveringArray.bestFitting` or `.generate`.
    public static func buildProfile(
        sequenceLength: Int,
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
    ) -> FiniteDomainProfile {
        let domainSize = UInt64(pickChoices.count)
        let parameters = (0 ..< sequenceLength).map { i in
            FiniteParameter(
                index: i,
                domainSize: domainSize,
                kind: .pick(choices: pickChoices),
            )
        }

        var totalSpace: UInt64 = 1
        for _ in 0 ..< sequenceLength {
            let (product, overflow) = totalSpace.multipliedReportingOverflow(by: domainSize)
            if overflow { totalSpace = .max; break }
            totalSpace = product
        }

        return FiniteDomainProfile(parameters: parameters, totalSpace: totalSpace)
    }

    /// Converts a covering array row into a `ChoiceTree` representing a command
    /// sequence that can be replayed through the array generator.
    ///
    /// Each row value selects a command type (pick branch) at the corresponding
    /// sequence position. The result is a `.sequence` node wrapping pick-site groups.
    ///
    /// - Parameters:
    ///   - row: The covering array row with command type indices per position.
    ///   - profile: The SCA profile (one pick parameter per position).
    ///   - sequenceLengthRange: The valid length range for the sequence metadata.
    /// - Returns: A `ChoiceTree` suitable for `Interpreters.replay`, or `nil` on failure.
    public static func buildTree(
        row: CoveringArrayRow,
        profile: FiniteDomainProfile,
        sequenceLengthRange: ClosedRange<UInt64>,
    ) -> ChoiceTree? {
        guard row.values.count == profile.parameters.count else { return nil }

        var elementTrees: [ChoiceTree] = []
        elementTrees.reserveCapacity(row.values.count)

        for (param, valueIndex) in zip(profile.parameters, row.values) {
            guard case let .pick(choices) = param.kind else { return nil }
            guard valueIndex < choices.count else { return nil }

            let chosen = choices[Int(valueIndex)]
            let branchIDs = choices.map(\.id)

            let branch = ChoiceTree.branch(
                siteID: chosen.siteID,
                weight: chosen.weight,
                id: chosen.id,
                branchIDs: branchIDs,
                choice: .just(""),
            )

            elementTrees.append(.group([.selected(branch)]))
        }

        return .sequence(
            length: UInt64(elementTrees.count),
            elements: elementTrees,
            ChoiceMetadata(
                validRange: sequenceLengthRange,
                isRangeExplicit: true,
            ),
        )
    }
}
