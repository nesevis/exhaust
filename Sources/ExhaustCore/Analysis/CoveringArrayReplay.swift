//
//  CoveringArrayReplay.swift
//  Exhaust
//

/// Converts covering array rows into `ChoiceTree` structures for replay.
public enum CoveringArrayReplay {
    /// Builds a `ChoiceTree` from a covering array row that can be replayed through the original generator via `Interpreters.replay`.
    ///
    /// - Parameters:
    ///   - row: The covering array row with value indices for each parameter.
    ///   - profile: The finite domain profile describing parameter structure.
    /// - Returns: A `ChoiceTree` suitable for `Interpreters.replay`, or `nil` if construction fails.
    public static func buildTree(row: CoveringArrayRow, profile: FiniteDomainProfile) -> ChoiceTree? {
        guard row.values.count == profile.parameters.count else { return nil }

        var trees: [ChoiceTree] = []
        trees.reserveCapacity(profile.parameters.count)

        for (param, valueIndex) in zip(profile.parameters, row.values) {
            guard let tree = buildParameterTree(param: param, valueIndex: valueIndex) else {
                return nil
            }
            trees.append(tree)
        }

        // If there's exactly one parameter, return its tree directly.
        // Otherwise wrap in a group (matching what zip produces).
        if trees.count == 1 {
            return trees[0]
        }
        return .group(trees)
    }

    // MARK: - Per-Parameter Tree Construction

    private static func buildParameterTree(param: FiniteParameter, valueIndex: UInt64) -> ChoiceTree? {
        switch param.kind {
        case let .chooseBits(range, tag):
            let bitPattern = range.lowerBound + valueIndex
            let choiceValue = ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
            let metadata = ChoiceMetadata(validRange: range, isRangeExplicit: true)
            return .choice(choiceValue, metadata)

        case let .pick(choices):
            guard valueIndex < choices.count else { return nil }
            let chosen = choices[Int(valueIndex)]

            // Build the sub-tree for the chosen branch's generator
            guard let subTree = buildSubTree(for: chosen.generator) else {
                return nil
            }

            let branchIDs = choices.map(\.id)
            let branch = ChoiceTree.branch(
                siteID: chosen.siteID,
                weight: chosen.weight,
                id: chosen.id,
                branchIDs: branchIDs,
                choice: subTree,
            )
            return .group([.selected(branch)])
        }
    }

    /// Builds a ChoiceTree for a pure sub-generator (one with no random choices).
    private static func buildSubTree(for gen: ReflectiveGenerator<Any>) -> ChoiceTree? {
        switch gen {
        case .pure:
            .just("")

        case let .impure(operation, _):
            switch operation {
            case .just:
                .just("")
            case let .contramap(_, next), let .prune(next):
                buildSubTree(for: next)
            default:
                nil
            }
        }
    }
}
