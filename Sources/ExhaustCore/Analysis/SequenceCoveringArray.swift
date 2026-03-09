// Sequence Covering Array (SCA) construction for state-machine property testing.
//
// An SCA guarantees every t-way ordered permutation of command types appears in at least one test sequence. Mathematically equivalent to a standard covering array where each parameter is a sequence position and each domain value is a command type. See Kuhn, Raunak & Kacker, "Ordered t-way Combinations for Testing State-based Systems".
//
// With argument-aware domains, each position's domain is the flattened union of (commandType × argumentCombinations), giving IPOG the ability to cover both command ordering AND argument value interactions across positions.

/// Builds covering arrays over command-type orderings for state-machine testing.
///
/// Each position in the command sequence becomes a parameter whose domain is the set of command types (pick branches). IPOG generates rows that guarantee every t-way ordered permutation of command types is tested.
///
/// When branches have analyzable arguments, the domain per position is the flattened union of `(commandType × argumentCombinations)`. Branches with small finite parameters contribute all values; branches with large ranges contribute boundary-value representatives. Unanalyzable branches fall back to 1 domain value with random arguments at replay.
///
/// For `c` command types, sequence length `L`, strength `t`, IPOG produces roughly `c^t × log(L)` rows.
/// - 5 commands, length 10, t=2: ~40–50 rows
/// - 10 commands, length 15, t=2: ~150–200 rows
public enum SequenceCoveringArray {
    /// SCA-specific finite threshold. Parameters with domain size above this are converted to boundary-value representatives. Lower than the 256 threshold in ``ChoiceTreeAnalysis`` because SCA domain sizes are the *sum* of all branch contributions — even "small" finite domains compound quickly.
    private static let scaFiniteThreshold: UInt64 = 10

    // MARK: - Legacy API (parameter-free branches only)

    /// Builds a `FiniteDomainProfile` where each parameter represents one position in the command sequence, with domain values being command type indices.
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

    /// Converts a covering array row into a `ChoiceTree` representing a command sequence that can be replayed through the array generator.
    ///
    /// Each row value selects a command type (pick branch) at the corresponding sequence position. The result is a `.sequence` node wrapping pick-site groups.
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

    // MARK: - Argument-Aware API

    /// Analyzes each branch's sub-generator to determine its argument domain.
    ///
    /// For each pick branch:
    /// - Parameter-free branches (no choices in the sub-generator) → `.parameterFree` (1 domain value)
    /// - Analyzable branches → `.analyzed([BoundaryParameter])` with SCA-threshold normalization
    /// - Unanalyzable branches (uses `getSize`, etc.) → `.unanalyzable` (1 domain value, random at replay)
    ///
    /// Parameters with domain size above ``scaFiniteThreshold`` are converted to boundary-value representatives to keep the per-position domain tractable.
    public static func analyzeBranches(
        _ pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
    ) -> [BranchArgProfile] {
        pickChoices.map { choice in
            if isParameterFree(choice.generator) {
                return .parameterFree
            }

            guard let result = ChoiceTreeAnalysis.analyze(choice.generator) else {
                return .unanalyzable
            }

            let normalized = normalizeToBoundaryParameters(result)
            if normalized.isEmpty {
                return .unanalyzable
            }
            return .analyzed(normalized)
        }
    }

    /// Builds a `FiniteDomainProfile` and `SCADomainMapping` incorporating argument domains.
    ///
    /// Each position's domain size is the sum of all branch contributions:
    /// - `.parameterFree` → 1
    /// - `.analyzed(params)` → product of parameter domain sizes
    /// - `.unanalyzable` → 1
    ///
    /// The mapping records the cumulative offsets so ``buildTree(row:profile:mapping:sequenceLengthRange:)`` can decompose flat domain indices back into branch + argument values.
    public static func buildProfile(
        sequenceLength: Int,
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        branchProfiles: [BranchArgProfile],
    ) -> (FiniteDomainProfile, SCADomainMapping) {
        var slots: [SCADomainSlot] = []
        var offset: UInt64 = 0

        for (index, profile) in branchProfiles.enumerated() {
            let contribution: UInt64
            switch profile {
            case .parameterFree, .unanalyzable:
                contribution = 1
            case let .analyzed(params):
                contribution = params.reduce(UInt64(1)) { acc, param in
                    let (product, overflow) = acc.multipliedReportingOverflow(by: param.domainSize)
                    return overflow ? .max : product
                }
            }

            slots.append(SCADomainSlot(
                branchIndex: index,
                flatOffset: offset,
                contribution: contribution,
                argProfile: profile,
            ))

            let (sum, overflow) = offset.addingReportingOverflow(contribution)
            offset = overflow ? .max : sum
        }

        let totalDomainSize = offset

        let parameters = (0 ..< sequenceLength).map { i in
            FiniteParameter(
                index: i,
                domainSize: totalDomainSize,
                kind: .pick(choices: pickChoices),
            )
        }

        var totalSpace: UInt64 = 1
        for _ in 0 ..< sequenceLength {
            let (product, overflow) = totalSpace.multipliedReportingOverflow(by: totalDomainSize)
            if overflow { totalSpace = .max; break }
            totalSpace = product
        }

        let finiteProfile = FiniteDomainProfile(parameters: parameters, totalSpace: totalSpace)
        let mapping = SCADomainMapping(
            slots: slots,
            totalDomainSize: totalDomainSize,
            pickChoices: pickChoices,
        )

        return (finiteProfile, mapping)
    }

    /// Converts a covering array row into a `ChoiceTree` using the SCA domain mapping.
    ///
    /// For each position, decomposes the flat domain index into a branch selection plus concrete argument values. Branches with analyzed arguments get sub-trees encoding specific parameter values; parameter-free and unanalyzable branches get `.just("")` sub-trees (unanalyzable branches will receive random arguments during replay since the sub-tree carries no argument constraints).
    ///
    /// - Parameters:
    ///   - row: The covering array row with flat domain indices per position.
    ///   - profile: The SCA profile (one parameter per position).
    ///   - mapping: The domain mapping from ``buildProfile(sequenceLength:pickChoices:branchProfiles:)``.
    ///   - sequenceLengthRange: The valid length range for the sequence metadata.
    /// - Returns: A `ChoiceTree` suitable for `Interpreters.replay`, or `nil` on failure.
    public static func buildTree(
        row: CoveringArrayRow,
        profile: FiniteDomainProfile,
        mapping: SCADomainMapping,
        sequenceLengthRange: ClosedRange<UInt64>,
    ) -> ChoiceTree? {
        guard row.values.count == profile.parameters.count else { return nil }

        var elementTrees: [ChoiceTree] = []
        elementTrees.reserveCapacity(row.values.count)

        let branchIDs = mapping.pickChoices.map(\.id)

        for valueIndex in row.values {
            guard let slot = findSlot(for: valueIndex, in: mapping.slots) else {
                return nil
            }

            let chosen = mapping.pickChoices[slot.branchIndex]

            let subTree: ChoiceTree
            switch slot.argProfile {
            case .parameterFree, .unanalyzable:
                subTree = .just("")
            case let .analyzed(params):
                let localIndex = valueIndex - slot.flatOffset
                guard let argTree = buildArgTree(
                    localIndex: localIndex,
                    params: params,
                ) else { return nil }
                subTree = argTree
            }

            let branch = ChoiceTree.branch(
                siteID: chosen.siteID,
                weight: chosen.weight,
                id: chosen.id,
                branchIDs: branchIDs,
                choice: subTree,
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

    // MARK: - Private Helpers

    private static func isParameterFree(_ gen: ReflectiveGenerator<Any>) -> Bool {
        switch gen {
        case .pure:
            return true
        case let .impure(op, _):
            switch op {
            case .just:
                return true
            case let .contramap(_, inner):
                return isParameterFree(inner)
            case let .prune(inner):
                return isParameterFree(inner)
            default:
                return false
            }
        }
    }

    /// Normalizes an analysis result to `[BoundaryParameter]` with SCA-specific thresholds.
    ///
    /// For `.finite` results, converts `FiniteParameter` → `BoundaryParameter`. For both result types, parameters with domain size above ``scaFiniteThreshold`` are recomputed as boundary-value representatives.
    private static func normalizeToBoundaryParameters(
        _ result: ChoiceTreeAnalysis.AnalysisResult,
    ) -> [BoundaryParameter] {
        switch result {
        case let .finite(profile):
            return profile.parameters.enumerated().map { i, param in
                switch param.kind {
                case let .chooseBits(range, tag):
                    if param.domainSize <= scaFiniteThreshold {
                        return BoundaryParameter(
                            index: i,
                            values: Array(range.lowerBound ... range.upperBound),
                            domainSize: param.domainSize,
                            kind: .finiteChooseBits(range: range, tag: tag),
                        )
                    } else {
                        let boundaryValues = BoundaryDomainAnalysis.computeBoundaryValues(
                            min: range.lowerBound, max: range.upperBound, tag: tag,
                        )
                        return BoundaryParameter(
                            index: i,
                            values: boundaryValues,
                            domainSize: UInt64(boundaryValues.count),
                            kind: .chooseBits(range: range, tag: tag),
                        )
                    }
                case let .pick(choices):
                    return BoundaryParameter(
                        index: i,
                        values: Array(0 ..< UInt64(choices.count)),
                        domainSize: UInt64(choices.count),
                        kind: .pick(choices: choices),
                    )
                }
            }

        case let .boundary(profile):
            return profile.parameters.enumerated().map { i, param in
                switch param.kind {
                case let .finiteChooseBits(range, tag) where param.domainSize > scaFiniteThreshold:
                    let boundaryValues = BoundaryDomainAnalysis.computeBoundaryValues(
                        min: range.lowerBound, max: range.upperBound, tag: tag,
                    )
                    return BoundaryParameter(
                        index: i,
                        values: boundaryValues,
                        domainSize: UInt64(boundaryValues.count),
                        kind: .chooseBits(range: range, tag: tag),
                    )
                default:
                    return BoundaryParameter(
                        index: i,
                        values: param.values,
                        domainSize: param.domainSize,
                        kind: param.kind,
                    )
                }
            }
        }
    }

    /// Finds the slot that contains the given flat domain index.
    private static func findSlot(
        for value: UInt64,
        in slots: [SCADomainSlot],
    ) -> SCADomainSlot? {
        for slot in slots {
            if value >= slot.flatOffset && value < slot.flatOffset + slot.contribution {
                return slot
            }
        }
        return nil
    }

    /// Decomposes a local index via mixed-radix into per-parameter value indices, then delegates to `BoundaryCoveringArrayReplay` to build the sub-tree.
    private static func buildArgTree(
        localIndex: UInt64,
        params: [BoundaryParameter],
    ) -> ChoiceTree? {
        var valueIndices = [UInt64](repeating: 0, count: params.count)
        var remainder = localIndex
        for idx in (0 ..< params.count).reversed() {
            let domain = params[idx].domainSize
            valueIndices[idx] = remainder % domain
            remainder /= domain
        }

        let row = CoveringArrayRow(values: valueIndices)
        let profile = BoundaryDomainProfile(parameters: params)
        return BoundaryCoveringArrayReplay.buildTree(row: row, profile: profile)
    }
}

// MARK: - SCA Argument Analysis Types

/// Per-branch analysis result for SCA domain construction.
///
/// Determines how many domain values a branch contributes to each position's combined domain in the covering array.
public enum BranchArgProfile {
    /// Branch generator has no parameters — contributes 1 domain value.
    case parameterFree
    /// Branch generator has analyzable parameters — contributes product-of-domainSizes domain values.
    case analyzed([BoundaryParameter])
    /// Branch generator is not analyzable — contributes 1 domain value (random args at replay).
    case unanalyzable
}

/// Maps a range of flat domain indices to a branch and its argument decomposition.
///
/// Each slot covers `[flatOffset, flatOffset + contribution)` in the flat domain. Used by ``SequenceCoveringArray/buildTree(row:profile:mapping:sequenceLengthRange:)`` to decompose a flat index into branch selection + argument values.
public struct SCADomainSlot {
    public let branchIndex: Int
    public let flatOffset: UInt64
    public let contribution: UInt64
    public let argProfile: BranchArgProfile
}

/// Lookup structure for converting flat domain indices to branch + argument values.
///
/// Shared between ``SequenceCoveringArray/buildProfile(sequenceLength:pickChoices:branchProfiles:)`` and ``SequenceCoveringArray/buildTree(row:profile:mapping:sequenceLengthRange:)``.
public struct SCADomainMapping {
    public let slots: [SCADomainSlot]
    public let totalDomainSize: UInt64
    public let pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>
}
