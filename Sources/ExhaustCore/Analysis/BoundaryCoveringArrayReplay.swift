//
//  BoundaryCoveringArrayReplay.swift
//  Exhaust
//

/// Converts covering array rows into `ChoiceTree` structures for boundary profile replay.
public enum BoundaryCoveringArrayReplay {
    /// Builds a `ChoiceTree` from a covering array row using boundary parameter values.
    ///
    /// Unlike `CoveringArrayReplay` which maps value indices to sequential offsets, this maps value indices to concrete boundary bit patterns stored in each parameter.
    public static func buildTree(row: CoveringArrayRow, profile: BoundaryDomainProfile) -> ChoiceTree? {
        guard row.values.count == profile.parameters.count else { return nil }

        var trees: [ChoiceTree] = []

        // Group parameters by their structural role
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
                    tag: tag,
                ) else { return nil }
                trees.append(tree)
                i += 1

            case let .sequenceLength(lengthRange):
                guard let (tree, consumed) = buildSequenceTree(
                    lengthParam: param,
                    lengthValueIndex: valueIndex,
                    lengthRange: lengthRange,
                    remainingParams: Array(profile.parameters.dropFirst(i + 1)),
                    remainingValues: Array(row.values.dropFirst(i + 1)),
                ) else { return nil }
                trees.append(tree)
                i += 1 + consumed

            case .sequenceElement:
                // Should not appear at top level without a preceding sequenceLength
                return nil

            case let .pick(choices):
                guard let tree = buildPickTree(
                    param: param,
                    valueIndex: valueIndex,
                    choices: choices,
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
        tag: TypeTag,
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
        remainingValues: [UInt64],
    ) -> (tree: ChoiceTree, consumedParams: Int)? {
        guard Int(lengthValueIndex) < lengthParam.values.count else { return nil }
        let length = lengthParam.values[Int(lengthValueIndex)]

        // Count how many element parameters follow
        var elementParamCount = 0
        for param in remainingParams {
            switch param.kind {
            case .sequenceElement, .finiteChooseBits, .chooseBits:
                // Check if this is still part of the same sequence's elements
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

        // Build element trees for elements up to `length`
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
                    tag: tag,
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
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
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
            choice: subTree,
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
            default:
                nil
            }
        }
    }
}
