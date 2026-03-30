//
//  CoveringArrayReplay.swift
//  Exhaust
//

/// Converts covering array rows into `ChoiceTree` structures for replay.
public enum CoveringArrayReplay {
    /// Builds a `ChoiceTree` from a covering array row that can be replayed through the original generator via `Interpreters.replay`.
    ///
    /// When the profile contains an original tree (from VACTI), walks the tree as a template and substitutes
    /// parameter values at matching positions. This preserves structural nodes like `.bind` that the flat
    /// parameter list doesn't capture. Falls back to flat construction when no original tree is available.
    ///
    /// - Parameters:
    ///   - row: The covering array row with value indices for each parameter.
    ///   - profile: The finite domain profile describing parameter structure.
    /// - Returns: A `ChoiceTree` suitable for `Interpreters.replay`, or `nil` if construction fails.
    public static func buildTree(
        row: CoveringArrayRow,
        profile: FiniteDomainProfile
    ) -> ChoiceTree? {
        guard row.values.count == profile.parameters.count else { return nil }

        if let originalTree = profile.originalTree {
            var paramIndex = 0
            return substituteParameters(
                in: originalTree,
                row: row,
                profile: profile,
                paramIndex: &paramIndex
            )
        }

        // Fallback: flat construction (no original tree available)
        var trees: [ChoiceTree] = []
        trees.reserveCapacity(profile.parameters.count)

        for (param, valueIndex) in zip(profile.parameters, row.values) {
            guard let tree = buildParameterTree(param: param, valueIndex: valueIndex) else {
                return nil
            }
            trees.append(tree)
        }

        if trees.count == 1 {
            return trees[0]
        }
        return .group(trees)
    }

    // MARK: - Template-Based Tree Substitution

    private static func substituteParameters(
        in tree: ChoiceTree,
        row: CoveringArrayRow,
        profile: FiniteDomainProfile,
        paramIndex: inout Int
    ) -> ChoiceTree? {
        switch tree {
        case .choice:
            guard paramIndex < profile.parameters.count else { return nil }
            let param = profile.parameters[paramIndex]
            let valueIndex = row.values[paramIndex]
            paramIndex += 1
            return buildParameterTree(param: param, valueIndex: valueIndex)

        case .just, .getSize, .resize:
            return tree

        case .group(_, isOpaque: true):
            return tree

        case let .group(children, _):
            if ChoiceTreeAnalysis.isPick(children) {
                guard paramIndex < profile.parameters.count else { return nil }
                let param = profile.parameters[paramIndex]
                let valueIndex = row.values[paramIndex]
                paramIndex += 1
                return buildParameterTree(param: param, valueIndex: valueIndex)
            }
            var newChildren: [ChoiceTree] = []
            for child in children {
                guard let newChild = substituteParameters(
                    in: child,
                    row: row,
                    profile: profile,
                    paramIndex: &paramIndex
                ) else {
                    return nil
                }
                newChildren.append(newChild)
            }
            return .group(newChildren)

        case let .bind(inner, bound):
            // Substitute parameters in inner only; pass bound through unchanged.
            guard let newInner = substituteParameters(
                in: inner,
                row: row,
                profile: profile,
                paramIndex: &paramIndex
            ) else {
                return nil
            }
            return .bind(inner: newInner, bound: bound)

        case let .selected(inner):
            guard let newInner = substituteParameters(
                in: inner,
                row: row,
                profile: profile,
                paramIndex: &paramIndex
            ) else {
                return nil
            }
            return .selected(newInner)

        case .sequence:
            // Sequences produce boundary parameters (sequenceLength/sequenceElement),
            // not finite parameters. If we reach here, the sequence is not behind a
            // bind — pass through unchanged as it shouldn't consume finite parameters.
            return tree

        case let .branch(siteID, weight, id, branchIDs, choice):
            guard let newChoice = substituteParameters(
                in: choice,
                row: row,
                profile: profile,
                paramIndex: &paramIndex
            ) else {
                return nil
            }
            return .branch(
                siteID: siteID,
                weight: weight,
                id: id,
                branchIDs: branchIDs,
                choice: newChoice
            )
        }
    }

    // MARK: - Per-Parameter Tree Construction

    private static func buildParameterTree(
        param: FiniteParameter,
        valueIndex: UInt64
    ) -> ChoiceTree? {
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
                choice: subTree
            )
            return .group([.selected(branch)])
        }
    }

    /// Builds a ChoiceTree for a pure sub-generator (one with no random choices).
    private static func buildSubTree(for gen: ReflectiveGenerator<Any>) -> ChoiceTree? {
        switch gen {
        case .pure:
            .just

        case let .impure(operation, _):
            switch operation {
            case .just:
                .just
            case let .contramap(_, next), let .prune(next):
                buildSubTree(for: next)
            case let .transform(_, inner):
                buildSubTree(for: inner)
            default:
                nil
            }
        }
    }
}
