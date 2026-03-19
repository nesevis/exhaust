//
//  BoundaryCoveringArrayReplay.swift
//  Exhaust
//

/// Converts covering array rows into `ChoiceTree` structures for boundary profile replay.
public enum BoundaryCoveringArrayReplay {
    /// Builds a `ChoiceTree` from a covering array row using boundary parameter values.
    ///
    /// When the profile contains an original tree (from VACTI), walks the tree as a template and substitutes
    /// parameter values at matching positions. This preserves structural nodes like `.bind` that the flat
    /// parameter list doesn't capture. Falls back to flat construction when no original tree is available.
    public static func buildTree(row: CoveringArrayRow, profile: BoundaryDomainProfile) -> ChoiceTree? {
        guard row.values.count == profile.parameters.count else { return nil }

        if let originalTree = profile.originalTree {
            var paramIndex = 0
            return substituteParameters(in: originalTree, row: row, profile: profile, paramIndex: &paramIndex)
        }

        return buildTreeFlat(row: row, profile: profile)
    }

    // MARK: - Template-Based Tree Substitution

    private static func substituteParameters(
        in tree: ChoiceTree,
        row: CoveringArrayRow,
        profile: BoundaryDomainProfile,
        paramIndex: inout Int
    ) -> ChoiceTree? {
        switch tree {
        case let .choice(_, metadata):
            guard paramIndex < profile.parameters.count else { return nil }
            let param = profile.parameters[paramIndex]
            let valueIndex = row.values[paramIndex]
            paramIndex += 1

            guard let range = metadata.validRange else { return nil }
            let tag = param.tag
            return buildChooseBitsTree(param: param, valueIndex: valueIndex, range: range, tag: tag)

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
                if case let .pick(choices) = param.kind {
                    return buildPickTree(param: param, valueIndex: valueIndex, choices: choices)
                }
                return nil
            }
            var newChildren: [ChoiceTree] = []
            for child in children {
                guard let newChild = substituteParameters(in: child, row: row, profile: profile, paramIndex: &paramIndex) else {
                    return nil
                }
                newChildren.append(newChild)
            }
            return .group(newChildren)

        case let .bind(inner, bound):
            guard let newInner = substituteParameters(in: inner, row: row, profile: profile, paramIndex: &paramIndex) else {
                return nil
            }
            return .bind(inner: newInner, bound: bound)

        case let .selected(inner):
            guard let newInner = substituteParameters(in: inner, row: row, profile: profile, paramIndex: &paramIndex) else {
                return nil
            }
            return .selected(newInner)

        case let .sequence(_, elements, metadata):
            // Consume length parameter
            guard paramIndex < profile.parameters.count else { return nil }
            let lengthParam = profile.parameters[paramIndex]
            let lengthValueIndex = row.values[paramIndex]
            paramIndex += 1

            guard Int(lengthValueIndex) < lengthParam.values.count else { return nil }
            let newLength = lengthParam.values[Int(lengthValueIndex)]

            // Substitute element parameters, stopping at newLength.
            // When used with per-length sub-array profiles, the profile only contains
            // element parameters accessible at this length, so paramIndex stays aligned
            // with subsequent non-sequence parameters.
            var newElements: [ChoiceTree] = []
            for (elementIndex, element) in elements.enumerated() {
                guard UInt64(elementIndex) < newLength else { break }
                guard let newElement = substituteParameters(in: element, row: row, profile: profile, paramIndex: &paramIndex) else {
                    return nil
                }
                newElements.append(newElement)
            }

            return .sequence(length: newLength, elements: newElements, metadata)

        case let .branch(siteID, weight, id, branchIDs, choice):
            guard let newChoice = substituteParameters(in: choice, row: row, profile: profile, paramIndex: &paramIndex) else {
                return nil
            }
            return .branch(siteID: siteID, weight: weight, id: id, branchIDs: branchIDs, choice: newChoice)
        }
    }

    // MARK: - Flat Construction (Fallback)

    private static func buildTreeFlat(row: CoveringArrayRow, profile: BoundaryDomainProfile) -> ChoiceTree? {
        var trees: [ChoiceTree] = []

        var i = 0
        while i < profile.parameters.count {
            let param = profile.parameters[i]
            let valueIndex = row.values[i]

            switch param.kind {
            case let .chooseBits(range, tag), let .finiteChooseBits(range, tag):
                guard let tree = buildChooseBitsTree(
                    param: param,
                    valueIndex: valueIndex,
                    range: range,
                    tag: tag
                ) else { return nil }
                trees.append(tree)
                i += 1

            case let .sequenceLength(lengthRange):
                guard let (tree, consumed) = buildSequenceTree(
                    lengthParam: param,
                    lengthValueIndex: valueIndex,
                    lengthRange: lengthRange,
                    remainingParams: Array(profile.parameters.dropFirst(i + 1)),
                    remainingValues: Array(row.values.dropFirst(i + 1))
                ) else { return nil }
                trees.append(tree)
                i += 1 + consumed

            case .sequenceElement:
                return nil

            case let .pick(choices):
                guard let tree = buildPickTree(
                    param: param,
                    valueIndex: valueIndex,
                    choices: choices
                ) else { return nil }
                trees.append(tree)
                i += 1
            }
        }

        if trees.count == 1 {
            return trees[0]
        }
        return .group(trees)
    }

    // MARK: - Tree Builders

    private static func buildChooseBitsTree(
        param: BoundaryParameter,
        valueIndex: UInt64,
        range: ClosedRange<UInt64>,
        tag: TypeTag
    ) -> ChoiceTree? {
        guard Int(valueIndex) < param.values.count else { return nil }
        let bitPattern = param.values[Int(valueIndex)]
        let choiceValue = ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
        let metadata = ChoiceMetadata(validRange: range, isRangeExplicit: true)
        return .choice(choiceValue, metadata)
    }

    private static func buildSequenceTree(
        lengthParam: BoundaryParameter,
        lengthValueIndex: UInt64,
        lengthRange: ClosedRange<UInt64>,
        remainingParams: [BoundaryParameter],
        remainingValues: [UInt64]
    ) -> (tree: ChoiceTree, consumedParams: Int)? {
        guard Int(lengthValueIndex) < lengthParam.values.count else { return nil }
        let length = lengthParam.values[Int(lengthValueIndex)]

        var elementParamCount = 0
        for param in remainingParams {
            switch param.kind {
            case .sequenceElement, .finiteChooseBits, .chooseBits:
                if case .sequenceElement = param.kind {
                    elementParamCount += 1
                } else {
                    break
                }
            default:
                break
            }
            if case .sequenceElement = param.kind {
                continue
            }
            break
        }

        var elementTrees: [ChoiceTree] = []
        for elementIdx in 0 ..< min(Int(length), elementParamCount) {
            let param = remainingParams[elementIdx]
            guard elementIdx < remainingValues.count else { return nil }
            let valueIndex = remainingValues[elementIdx]

            switch param.kind {
            case let .sequenceElement(_, range, tag):
                guard let tree = buildChooseBitsTree(
                    param: param,
                    valueIndex: valueIndex,
                    range: range,
                    tag: tag
                ) else { return nil }
                elementTrees.append(tree)

            default:
                return nil
            }
        }

        let metadata = ChoiceMetadata(validRange: lengthRange, isRangeExplicit: true)
        let tree = ChoiceTree.sequence(length: length, elements: elementTrees, metadata)
        return (tree, elementParamCount)
    }

    private static func buildPickTree(
        param _: BoundaryParameter,
        valueIndex: UInt64,
        choices: ContiguousArray<ReflectiveOperation.PickTuple>
    ) -> ChoiceTree? {
        guard valueIndex < choices.count else { return nil }
        let chosen = choices[Int(valueIndex)]

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
            case let .transform(_, inner):
                buildSubTree(for: inner)
            default:
                nil
            }
        }
    }
}

// MARK: - BoundaryParameter tag helper

extension BoundaryParameter {
    var tag: TypeTag {
        switch kind {
        case let .chooseBits(_, tag), let .finiteChooseBits(_, tag):
            tag
        case let .sequenceElement(_, _, tag):
            tag
        case .sequenceLength:
            .uint64
        case .pick:
            .uint64
        }
    }
}
