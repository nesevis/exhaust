/// Reconstructs covering rows for both enumerable and large-domain models using one shape-directed traversal.
package enum CoveringArrayReplay {
    /// Preserves the analysis template's wrappers and rejects rows that do not consume exactly the modeled parameters.
    public static func buildTree(row: CoveringArrayRow, profile: EnumerableDomainProfile) -> ChoiceTree? {
        let parameters = Parameters.enumerable(profile.parameters)
        if let tree = profile.template?.substitutionTemplate {
            return rebuild(tree, row: row, parameters: parameters)
        }
        guard parameters.accepts(row) else { return nil }
        var trees: [ChoiceTree] = []
        for (parameter, valueIndex) in zip(profile.parameters, row.values) {
            guard let tree = buildParameterTree(param: parameter, valueIndex: valueIndex) else { return nil }
            trees.append(tree)
        }
        return trees.count == 1 ? trees[0] : .group(trees)
    }

    /// Uses the same template traversal as enumerable replay; only value lookup and composite sequence construction differ.
    public static func buildTree(row: CoveringArrayRow, profile: LargeDomainProfile) -> ChoiceTree? {
        let parameters = Parameters.large(profile.parameters)
        if let tree = profile.originalTree {
            return rebuild(tree, row: row, parameters: parameters)
        }
        guard parameters.accepts(row) else { return nil }
        return buildTreeFlat(row: row, profile: profile)
    }

    /// Borrows the profile arrays through value semantics without expanding enumerable ranges into per-row lookup tables.
    private enum Parameters {
        case enumerable([EnumerableParameter])
        case large([ScreeningParameter])

        var count: Int {
            switch self {
                case let .enumerable(parameters): parameters.count
                case let .large(parameters): parameters.count
            }
        }

        func accepts(_ row: CoveringArrayRow) -> Bool {
            guard row.values.count == count else { return false }
            switch self {
                case let .enumerable(parameters):
                    return zip(parameters, row.values).allSatisfy { $1 < $0.domainSize }
                case let .large(parameters):
                    return zip(parameters, row.values).allSatisfy { $1 < $0.domainSize }
            }
        }
    }

    /// Checks final consumption at the root and independently inside each composite slot, rather than silently accepting leftover factors.
    private static func rebuild(
        _ tree: ChoiceTree,
        row: CoveringArrayRow,
        parameters: Parameters,
        scope: ScreeningScope = .root
    ) -> ChoiceTree? {
        guard parameters.accepts(row) else { return nil }
        var parameterIndex = 0
        guard let result = substituteParameters(
            in: tree,
            row: row,
            parameters: parameters,
            parameterIndex: &parameterIndex,
            scope: scope
        ), parameterIndex == parameters.count else { return nil }
        return result
    }

    private static func substituteParameters(
        in tree: ChoiceTree,
        row: CoveringArrayRow,
        parameters: Parameters,
        parameterIndex: inout Int,
        scope: ScreeningScope
    ) -> ChoiceTree? {
        switch tree.screeningShape(in: scope) {
            case .preserved:
                return tree
            case .invalid:
                return nil
            case let .choice(value, metadata):
                guard parameterIndex < parameters.count else { return nil }
                defer { parameterIndex += 1 }
                return substituteChoice(
                    value,
                    metadata: metadata,
                    parameters: parameters,
                    index: parameterIndex,
                    valueIndex: row.values[parameterIndex]
                )
            case .pick:
                guard parameterIndex < parameters.count else { return nil }
                defer { parameterIndex += 1 }
                switch parameters {
                    case let .enumerable(factors):
                        guard case .pick = factors[parameterIndex].kind else { return nil }
                        return buildParameterTree(param: factors[parameterIndex], valueIndex: row.values[parameterIndex])
                    case let .large(factors):
                        let parameter = factors[parameterIndex]
                        guard case let .pick(choices) = parameter.kind else { return nil }
                        return buildPickTree(param: parameter, valueIndex: row.values[parameterIndex], choices: choices)
                }
            case let .singleton(branch, isZip):
                guard let choice = substituteParameters(
                    in: branch.choice,
                    row: row,
                    parameters: parameters,
                    parameterIndex: &parameterIndex,
                    scope: scope
                ) else { return nil }
                return .group([.branch(
                    fingerprint: branch.fingerprint,
                    weight: branch.weight,
                    id: branch.id,
                    branchCount: branch.branchCount,
                    choice: choice,
                    isSelected: branch.isSelected
                )], isZip: isZip)
            case let .group(children, isZip):
                guard let rebuilt = substituteChildren(children, row: row, parameters: parameters, parameterIndex: &parameterIndex, scope: scope) else { return nil }
                return .group(rebuilt, isZip: isZip)
            case let .resize(size, children):
                guard let rebuilt = substituteChildren(children, row: row, parameters: parameters, parameterIndex: &parameterIndex, scope: scope) else { return nil }
                return .resize(newSize: size, choices: rebuilt)
            case let .bind(fingerprint, inner, bound, visitsBound):
                guard let rebuiltInner = substituteParameters(in: inner, row: row, parameters: parameters, parameterIndex: &parameterIndex, scope: scope) else { return nil }
                guard visitsBound else { return .bind(fingerprint: fingerprint, inner: rebuiltInner, bound: bound) }
                guard let rebuiltBound = substituteParameters(in: bound, row: row, parameters: parameters, parameterIndex: &parameterIndex, scope: scope) else { return nil }
                return .bind(fingerprint: fingerprint, inner: rebuiltInner, bound: rebuiltBound)
            case let .sequence(elements, metadata):
                guard case let .large(factors) = parameters else { return nil }
                return substituteSequence(elements, metadata: metadata, row: row, parameters: factors, parameterIndex: &parameterIndex)
        }
    }

    private static func substituteChildren(
        _ children: [ChoiceTree],
        row: CoveringArrayRow,
        parameters: Parameters,
        parameterIndex: inout Int,
        scope: ScreeningScope
    ) -> [ChoiceTree]? {
        var result: [ChoiceTree] = []
        for child in children {
            guard let rebuilt = substituteParameters(in: child, row: row, parameters: parameters, parameterIndex: &parameterIndex, scope: scope) else { return nil }
            result.append(rebuilt)
        }
        return result
    }

    /// Rejects factor-kind and domain mismatches before consuming a value, including a pick supplied at a numeric site.
    private static func substituteChoice(
        _ value: ChoiceValue,
        metadata: ChoiceMetadata,
        parameters: Parameters,
        index: Int,
        valueIndex: UInt64
    ) -> ChoiceTree? {
        switch parameters {
            case let .enumerable(factors):
                let parameter = factors[index]
                guard case let .chooseBits(range, tag) = parameter.kind,
                      range == metadata.validRange, tag == value.tag else { return nil }
                return buildParameterTree(param: parameter, valueIndex: valueIndex)
            case let .large(factors):
                let parameter = factors[index]
                switch parameter.kind {
                    case let .chooseBits(range, tag), let .enumerableChooseBits(range, tag), let .sequenceElement(_, range, tag):
                        guard range == metadata.validRange, tag == value.tag else { return nil }
                        return buildChooseBitsTree(param: parameter, valueIndex: valueIndex, range: range, tag: tag)
                    default:
                        return nil
                }
        }
    }

    private static func substituteSequence(
        _ elements: [ChoiceTree],
        metadata: ChoiceMetadata,
        row: CoveringArrayRow,
        parameters: [ScreeningParameter],
        parameterIndex: inout Int
    ) -> ChoiceTree? {
        guard parameterIndex < parameters.count else { return nil }
        let parameter = parameters[parameterIndex]
        let valueIndex = row.values[parameterIndex]
        parameterIndex += 1
        switch parameter.kind {
            case let .compositeSequence(range, slotParameters, halvedPairs, lengthSlots):
                guard range == metadata.validRange,
                      let slot = findLengthSlot(for: valueIndex, in: lengthSlots) else { return nil }
                let effective = (halvedPairs && slot.activeElementCount >= 2)
                    ? ChoiceTreeAnalysis.halveElementSlotParams(slotParameters) : slotParameters
                guard slot.activeElementCount <= effective.count,
                      slot.activeElementCount <= elements.count,
                      effective.prefix(slot.activeElementCount).allSatisfy({ $0.allSatisfy { $0.domainSize > 0 } }) else { return nil }
                let values = decomposeCompositeIndex(valueIndex - slot.flatOffset, activeSlotParams: Array(effective.prefix(slot.activeElementCount)))
                var result: [ChoiceTree] = []
                var offset = 0
                for (index, element) in elements.enumerated() {
                    guard UInt64(index) < slot.length else { break }
                    guard index < slot.activeElementCount else {
                        result.append(element)
                        continue
                    }
                    let factors = effective[index]
                    let subRow = CoveringArrayRow(values: Array(values[offset ..< offset + factors.count]))
                    guard let rebuilt = rebuild(element, row: subRow, parameters: .large(factors), scope: .element(index)) else { return nil }
                    result.append(rebuilt)
                    offset += factors.count
                }
                return .sequence(elements: result, metadata: metadata)
            case let .sequenceLength(range):
                guard range == metadata.validRange, valueIndex < UInt64(parameter.values.count) else { return nil }
                let length = parameter.values[Int(valueIndex)]
                let analyzedSlots = min(2, elements.count, Int(clamping: range.upperBound))
                var result: [ChoiceTree] = []
                for (index, element) in elements.enumerated() {
                    guard UInt64(index) < length else { break }
                    guard index < analyzedSlots else {
                        result.append(element)
                        continue
                    }
                    guard let rebuilt = substituteParameters(in: element, row: row, parameters: .large(parameters), parameterIndex: &parameterIndex, scope: .element(index)) else { return nil }
                    result.append(rebuilt)
                }
                return .sequence(elements: result, metadata: metadata)
            default:
                return nil
        }
    }

    private static func buildParameterTree(
        param: EnumerableParameter,
        valueIndex: UInt64
    ) -> ChoiceTree? {
        switch param.kind {
            case let .chooseBits(range, tag):
                guard valueIndex <= range.upperBound - range.lowerBound else { return nil }
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

                let branch = ChoiceTree.branch(
                    fingerprint: chosen.fingerprint,
                    weight: chosen.weight,
                    id: chosen.id,
                    branchCount: UInt64(choices.count),
                    choice: subTree,
                    isSelected: true
                )
                return .group([branch])
        }
    }

    // MARK: - Flat Construction (Fallback)

    private static func buildTreeFlat(
        row: CoveringArrayRow,
        profile: LargeDomainProfile
    ) -> ChoiceTree? {
        var trees: [ChoiceTree] = []

        var i = 0
        while i < profile.parameters.count {
            let param = profile.parameters[i]
            let valueIndex = row.values[i]

            switch param.kind {
                case let .chooseBits(range, tag),
                     let .enumerableChooseBits(range, tag),
                     let .sequenceElement(_, range, tag):
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

                case let .compositeSequence(lengthRange, elementSlotParams, halvedPairs, lengthSlots):
                    guard let slot = findLengthSlot(for: valueIndex, in: lengthSlots) else {
                        return nil
                    }
                    let effectiveParams = (halvedPairs && slot.activeElementCount >= 2)
                        ? ChoiceTreeAnalysis.halveElementSlotParams(elementSlotParams)
                        : elementSlotParams
                    let elementValues = decomposeCompositeIndex(
                        valueIndex - slot.flatOffset,
                        activeSlotParams: Array(effectiveParams.prefix(slot.activeElementCount))
                    )
                    var elementTrees: [ChoiceTree] = []
                    var flatIdx = 0
                    for elemIdx in 0 ..< Int(slot.length) {
                        if elemIdx < slot.activeElementCount {
                            let slotParams = effectiveParams[elemIdx]
                            let subRow = CoveringArrayRow(values: Array(elementValues[flatIdx ..< flatIdx + slotParams.count]))
                            let subProfile = LargeDomainProfile(parameters: slotParams)
                            guard let elemTree = Self.buildTree(row: subRow, profile: subProfile) else {
                                return nil
                            }
                            elementTrees.append(elemTree)
                            flatIdx += slotParams.count
                        } else {
                            elementTrees.append(.just)
                        }
                    }
                    let seqMetadata = ChoiceMetadata(validRange: lengthRange, isRangeExplicit: true)
                    trees.append(.sequence(elements: elementTrees, metadata: seqMetadata))
                    i += 1

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

    /// Converts a covering array value index into a ``ChoiceTree`` leaf for a chooseBits parameter.
    ///
    /// Looks up the concrete bit pattern at `valueIndex` in the parameter's problematic value table, then wraps it in a `.choice` node with the original range metadata so the materializer can validate it.
    private static func buildChooseBitsTree(
        param: ScreeningParameter,
        valueIndex: UInt64,
        range: ClosedRange<UInt64>,
        tag: TypeTag
    ) -> ChoiceTree? {
        guard valueIndex < UInt64(param.values.count) else { return nil }
        let bitPattern = param.values[Int(valueIndex)]
        let choiceValue = ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
        let metadata = ChoiceMetadata(validRange: range, isRangeExplicit: true)
        return .choice(choiceValue, metadata)
    }

    private static func buildSequenceTree(
        lengthParam: ScreeningParameter,
        lengthValueIndex: UInt64,
        lengthRange: ClosedRange<UInt64>,
        remainingParams: [ScreeningParameter],
        remainingValues: [UInt64]
    ) -> (tree: ChoiceTree, consumedParams: Int)? {
        guard lengthValueIndex < UInt64(lengthParam.values.count) else { return nil }
        let length = lengthParam.values[Int(lengthValueIndex)]

        var elementParamCount = 0
        for param in remainingParams {
            guard case .sequenceElement = param.kind else { break }
            elementParamCount += 1
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
        let tree = ChoiceTree.sequence(elements: elementTrees, metadata: metadata)
        return (tree, elementParamCount)
    }

    private static func buildPickTree(
        param _: ScreeningParameter,
        valueIndex: UInt64,
        choices: ContiguousArray<ReflectiveOperation.PickTuple>
    ) -> ChoiceTree? {
        guard valueIndex < choices.count else { return nil }
        let chosen = choices[Int(valueIndex)]

        guard let subTree = buildSubTree(for: chosen.generator) else {
            return nil
        }

        let branch = ChoiceTree.branch(
            fingerprint: chosen.fingerprint,
            weight: chosen.weight,
            id: chosen.id,
            branchCount: UInt64(choices.count),
            choice: subTree,
            isSelected: true
        )
        return .group([branch])
    }

    // MARK: - Composite Sequence Helpers

    /// Finds the length slot containing the given composite index via linear scan. Slots are sorted by `flatOffset`; there are at most four (lengths 0, 1, 2, lowerBound).
    private static func findLengthSlot(
        for compositeIndex: UInt64,
        in slots: [SequenceLengthSlot]
    ) -> SequenceLengthSlot? {
        for slot in slots.reversed() where compositeIndex >= slot.flatOffset {
            guard compositeIndex - slot.flatOffset < slot.contribution else { return nil }
            return slot
        }
        return nil
    }

    /// Decomposes a local index within a length slot into per-parameter value indices via mixed-radix arithmetic.
    private static func decomposeCompositeIndex(
        _ localIndex: UInt64,
        activeSlotParams: [[ScreeningParameter]]
    ) -> [UInt64] {
        let flatParams = activeSlotParams.flatMap { $0 }
        guard flatParams.isEmpty == false else { return [] }
        var indices = [UInt64](repeating: 0, count: flatParams.count)
        var remainder = localIndex
        for idx in (0 ..< flatParams.count).reversed() {
            let domain = flatParams[idx].domainSize
            indices[idx] = remainder % domain
            remainder /= domain
        }
        return indices
    }

    private static func buildSubTree(for gen: AnyGenerator) -> ChoiceTree? {
        SharedInterpreterHelpers.buildParameterFreeSubTree(for: gen)
    }
}
