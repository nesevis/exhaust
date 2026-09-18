import Foundation

extension Interpreters {
    // MARK: - Backward Interpreter for Individual Operations

    /// Interprets a single ``ReflectiveOperation`` in the backward direction, producing candidate intermediate values and partial choice tree paths.
    ///
    /// For chooseBits: inverts the bit-pattern encoding to recover the original value. For pick: tries each branch's sub-generator via ``reflectRecursive`` and returns the branch whose output matches `finalOutput`. For sequence: reflects each element independently. For contramap: applies the backward transform to extract the inner value from `finalOutput`.
    static func interpretOperationBackward(
        _ op: ReflectiveOperation,
        onFinalOutput finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch op {
            // A nil onFinalOutput at this point means the generator produces an Optional type.
            case let .contramap(transform, nextGen):
                return try reflectContramapOperation(
                    transform: transform,
                    nextGen: nextGen,
                    finalOutput: finalOutput,
                    context: context
                )

            case let .prune(nextGen):
                return try reflectPruneOperation(nextGen: nextGen, finalOutput: finalOutput, context: context)

            case let .pick(choices, _):
                return try reflectPickOperation(choices: choices, finalOutput: finalOutput, context: context)

            case let .chooseBits(min, max, tag, isRangeExplicit, scaling, typeTagPayload):
                return try reflectChooseBitsOperation(
                    min: min,
                    max: max,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    scaling: scaling,
                    typeTagPayload: typeTagPayload,
                    finalOutput: finalOutput,
                    context: context
                )

            case let .just(value):
                // Avoid expensive string interpolation and prefix operations
                return [(value: value, path: [.just])]

            case .getSize:
                // A surrounding resize fixes the size seen by the nested generator. Without one, reflection keeps using size 100 so size-dependent generators expose their full range.
                if let sizeOverride = context.sizeOverride {
                    return [(value: sizeOverride, path: [.getSize(sizeOverride)])]
                }
                let derivedSize: UInt64 = switch finalOutput {
                    case let size as UInt64:
                        size
                    case let sequence as any Sequence:
                        UInt64(sequence.underestimatedCount)
                    default:
                        0
                }
                return [(value: derivedSize, path: [.getSize(100)])]

            case let .resize(newSize, nextGen):
                return try reflectResizeOperation(
                    newSize: newSize,
                    nextGen: nextGen,
                    finalOutput: finalOutput,
                    context: context
                )

            case let .sequence(lengthGen, elementGen, _):
                return try reflectSequenceOperation(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    finalOutput: finalOutput,
                    context: context
                )

            case let .zip(generators, _):
                return try reflectZipOperation(generators: generators, finalOutput: finalOutput, context: context)

            case let .filter(gen, _, _, _, _):
                return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput, context: context)

            case let .classify(gen, _, _):
                return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput, context: context)

            case let .unique(gen, _, _):
                return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput, context: context)

            case let .transform(kind, inner):
                return try reflectTransformOperation(
                    kind: kind,
                    inner: inner,
                    finalOutput: finalOutput,
                    context: context
                )
        }
    }

    private static func reflectContramapOperation(
        transform: (Any) throws -> Any?,
        nextGen: AnyGenerator,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let subValue = try transform(finalOutput) else {
            throw ReflectionError.contramapWasWrongType
        }
        return try reflectRecursive(nextGen, onFinalOutput: subValue, context: context).map { ($0.value, $0.path) }
    }

    private static func reflectPruneOperation(
        nextGen: AnyGenerator,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        do {
            return try reflectRecursive(nextGen, onFinalOutput: finalOutput, context: context).map { ($0.value, $0.path) }
        } catch ReflectionError.reflectedNil {
            return []
        } catch ReflectionError.contramapWasWrongType {
            return []
        }
    }

    private static func reflectPickOperation(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let branchCount = UInt64(choices.count)
        let fingerprint = choices[0].fingerprint
        // On a backtrack node only the framework-built absent arm may record an outer nil: a user arm that reflects nil is a withdrawn arm, and exact materialization rejects a recorded arm that replays nil. An always node has no absent arm and cannot have produced nil at all.
        let candidates: ContiguousArray<ReflectiveOperation.PickTuple>
        if choices[0].isBacktrack, isNilOptional(finalOutput) {
            guard let absent = BacktrackAudition.absentArm(in: choices) else {
                return []
            }
            candidates = [absent]
        } else {
            candidates = choices
        }
        var deferredBranchError: ReflectionError?
        let results = try candidates.flatMap { choice -> [(value: Any, fingerprint: UInt64, weight: UInt64, id: UInt64, isPicked: Bool, path: ChoiceTree)] in
            do {
                let reflectionPaths = try reflectRecursive(choice.generator, onFinalOutput: finalOutput, context: context.enteringPickArm())
                let value = reflectionPaths.firstNonNil { $0.value }

                var isPicked = false
                if let equatableOutput = finalOutput as? any Equatable,
                   let equatableValue = value as? any Equatable
                {
                    isPicked = equatableOutput.isEqual(equatableValue)
                } else if let convertible = value as? any BitPatternConvertible {
                    isPicked = choice.generator.associatedRange?
                        .contains(convertible.bitPattern64) ?? false
                } else {
                    // Compare the first candidate's value directly rather than through `value` (an `Any?`): re-boxing that optional channel as `Any` wraps a nil candidate in an artifact `.some` layer, which makes the nil branch spuriously match `.some(nil)` outputs and vice versa.
                    isPicked = reflectionPaths.first.map { structurallyEqual($0.value, finalOutput) } ?? false
                }

                var results: [(value: Any, fingerprint: UInt64, weight: UInt64, id: UInt64, isPicked: Bool, path: ChoiceTree)] = []
                if isPicked {
                    for (value, pathTree) in reflectionPaths {
                        guard let path = pathTree.first else {
                            continue
                        }
                        results.append((value, fingerprint, choice.weight, choice.id, true, path))
                    }
                }
                return results

            } catch let error as ReflectionError {
                switch error {
                    case .reflectedNil, .contramapWasWrongType:
                        return []
                    case .inputWasOutOfGeneratorRange:
                        // An out-of-range branch still lets a later branch produce the value. If every branch rejects it, preserve the range error instead of turning the rejection into nil.
                        if deferredBranchError == nil {
                            deferredBranchError = error
                        }
                        return []
                    default:
                        // Any other reflection failure inside a branch probe also means this branch cannot produce the value (for example a forward-only map on the untaken branch of a nested optional). Remember the first one so an all-branches failure below still surfaces a diagnosis instead of silently reflecting an empty pick.
                        if deferredBranchError == nil {
                            deferredBranchError = error
                        }
                        return []
                }
            }
        }
        if results.isEmpty {
            if let deferredBranchError {
                throw deferredBranchError
            }
            return []
        }

        // Only mark the first matching branch as `.selected` — a pick site should have exactly one selected branch, matching VACTI's output.
        // When multiple branches can produce the same value (non-injective generators), reflection picks the first match deterministically.
        var hasSelected = false
        let mappedBranches = results.map {
            let branch = ChoiceTree.branch(
                fingerprint: $0.fingerprint,
                weight: $0.weight,
                id: $0.id,
                branchCount: branchCount,
                choice: $0.path
            )
            if hasSelected == false {
                hasSelected = true
                return branch.selecting()
            }
            return branch
        }
        return [(finalOutput, [ChoiceTree.group(mappedBranches)])]
    }

    /// Reconstructs a choice while validating explicit ranges against an enclosing resize's effective size-scaled range.
    private static func reflectChooseBitsOperation(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        typeTagPayload: TypeTagPayload?,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let declaredRange = min ... max
        let effectiveRange = switch (scaling, context.sizeOverride) {
            case let (.some(scaling), .some(sizeOverride)):
                Gen.applyScaling(
                    min: min,
                    max: max,
                    tag: tag,
                    scaling: scaling,
                    size: sizeOverride
                )
            default:
                declaredRange
        }

        // Prefer a value's explicit bit-pattern representation to sequence cardinality when it offers both. Cardinality is only a fallback for sequence length reflection; pinned sizes take precedence over either.
        var convertibleValue: (any BitPatternConvertible)?
        if scaling?.isPinnedToSize == true, context.sizeOverride != nil {
            convertibleValue = UInt64(effectiveRange.lowerBound)
        } else if let convertible = finalOutput as? any BitPatternConvertible {
            convertibleValue = convertible
        } else if let sequence = finalOutput as? any Sequence {
            convertibleValue = UInt64(sequence.underestimatedCount)
        }
        guard let convertibleValue else {
            throw ReflectionError.chooseBitsCouldNotConvertValue("\(finalOutput)")
        }

        let bitPattern = convertibleValue.bitPattern64
        if isRangeExplicit, effectiveRange.contains(bitPattern) == false {
            // Float types: allow NaN/infinity through so problematic-value screening counterexamples are reflectable, but enforce the range for finite values.
            let range = ChoiceValue(bitPattern, tag: tag).displayRange(effectiveRange)
            if tag.isFloatingPoint {
                let numericValue = tag.numericDoubleValue(forBitPattern: bitPattern)
                if numericValue.isFinite {
                    throw ReflectionError.inputWasOutOfGeneratorRange(
                        String(describing: convertibleValue),
                        range: range
                    )
                }
            } else {
                throw ReflectionError.inputWasOutOfGeneratorRange(
                    String(describing: convertibleValue),
                    range: range
                )
            }
        }

        let reflectedRange = isRangeExplicit
            ? declaredRange
            : type(of: convertibleValue).bitPatternRange

        let metadata = ChoiceMetadata(
            validRange: reflectedRange,
            isRangeExplicit: isRangeExplicit,
            typeTagPayload: typeTagPayload,
            isPinnedToSize: scaling?.isPinnedToSize == true
        )
        let choiceTree = ChoiceTree.choice(
            .init(convertibleValue, tag: tag),
            metadata
        )
        return [(value: convertibleValue, path: [choiceTree])]
    }

    /// Reflects the nested generator with `newSize`; recursive value passing restores any outer scope after this call returns.
    private static func reflectResizeOperation(
        newSize: UInt64,
        nextGen: AnyGenerator,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let nestedResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput, context: context.resized(to: newSize))
        return nestedResults.map { result in
            (value: result.value, path: [.resize(newSize: newSize, choices: result.path)])
        }
    }

    private static func reflectSequenceOperation(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let targetArray = finalOutput as? any Sequence else {
            throw ReflectionError.inputWasWrongForSequence("\(finalOutput)")
        }

        var combinedPath: [ChoiceTree] = []
        var combinedResults: [Any] = []

        for elementTarget in targetArray {
            let elementResults = try reflectRecursive(elementGen, onFinalOutput: elementTarget, context: context)
            guard let (value, path) = elementResults.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement("\(elementTarget)")
            }
            combinedResults.append(value)
            combinedPath.append(path.count == 1 ? path[0] : .group(path))
        }

        let targetLength = UInt64(combinedPath.count)
        let lengthReflection = try reflectRecursive(lengthGen, onFinalOutput: targetLength, context: context)
        let reflectedMetadata = lengthReflection.firstNonNil { result in
            result.path.firstNonNil { tree in
                let metadata = tree.metadata
                return metadata.validRange == nil ? nil : metadata
            }
        }
        let validRange = reflectedMetadata?.validRange
            ?? lengthGen.associatedRange
            ?? UInt64.bitPatternRange
        let isLengthRangeExplicit = reflectedMetadata?.isRangeExplicit
            ?? (lengthGen.associatedRange != nil)

        let finalTree = ChoiceTree.sequence(
            elements: combinedPath,
            metadata: ChoiceMetadata(
                validRange: validRange,
                isRangeExplicit: isLengthRangeExplicit
            )
        )
        return [(value: combinedResults, path: [finalTree])]
    }

    /// Reflects one candidate per zip component so reconstructed values and paths retain their positional correspondence.
    static func reflectZipOperation(
        generators: ContiguousArray<AnyGenerator>,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let outputs = finalOutput as? [Any], outputs.count == generators.count else {
            throw ReflectionError.zipWasWrongLengthOrType
        }
        var results = [Any]()
        var paths = [ChoiceTree]()

        for (generator, output) in zip(generators, outputs) {
            let candidates = try Self.reflectRecursive(generator, onFinalOutput: output, context: context)
            // Exactly one value per generator. Consumers read `results` positionally against the declared arity, so a component contributing zero or several entries shifts every later slot onto the wrong generator, and the type-erased read then force-casts across types.
            guard let (value, path) = candidates.first else {
                throw ReflectionError.couldNotReflectOnZipElement("\(output)")
            }
            paths.append(path.count == 1 ? path[0] : .group(path))
            results.append(value)
        }

        return [(value: results, path: [.group(paths, isZip: true)])]
    }

    private static func reflectPassthroughOperation(
        gen: AnyGenerator,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        try reflectRecursive(gen, onFinalOutput: finalOutput, context: context).map { ($0.value, $0.path) }
    }

    private static func reflectTransformOperation(
        kind: TransformKind,
        inner: AnyGenerator,
        finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch kind {
            case let .map(forward, backward, inputType, outputType):
                if let backward {
                    // Bidirectional map (`mapped(forward:backward:)`): apply the user-contract inverse, reflect the inner generator against the recovered input, then reconstruct the mapped value for upstream matching.
                    let innerValue = try backward(finalOutput)
                    let reflected = try reflectRecursive(inner, onFinalOutput: innerValue, context: context)
                    return try reflected.map { result in
                        try (value: forward(result.value), path: result.path)
                    }
                }
                if let inputBPC = inputType as? any BitPatternConvertible.Type,
                   let outputValue = finalOutput as? any BitPatternConvertible
                {
                    let inverted = inputBPC.init(bitPattern64: outputValue.bitPattern64)
                    do {
                        let roundTripped = try forward(inverted)
                        if let roundTrippedBPC = roundTripped as? any BitPatternConvertible,
                           roundTrippedBPC.bitPattern64 == outputValue.bitPattern64
                        {
                            let reflected = try reflectRecursive(inner, onFinalOutput: inverted, context: context)
                            return reflected.map { result in
                                (value: roundTripped, path: result.path)
                            }
                        }
                    } catch {
                        // Forward application failed — fall through to error
                    }
                }
                throw ReflectionError.forwardOnlyMap(
                    inputType: "\(inputType)",
                    outputType: "\(outputType)"
                )
            case let .isomorph(forward, backward, _, _):
                // Guaranteed invertible by construction (framework-authored pairs only), so no forward-only error path exists here. Reconstruct the outer value for upstream matching after reflecting the recovered inner value.
                let innerValue = try backward(finalOutput)
                let reflected = try reflectRecursive(inner, onFinalOutput: innerValue, context: context)
                return try reflected.map { result in
                    try (value: forward(result.value), path: result.path)
                }
            case let .bind(fingerprint, forward, backward, inputType, outputType):
                guard let backward else {
                    throw ReflectionError.forwardOnlyBind(
                        inputType: "\(inputType)",
                        outputType: "\(outputType)"
                    )
                }
                // Xia et al.'s comap at bind sites: extract the inner value from the final output.
                let innerValue = try backward(finalOutput)
                // Reflect the inner generator against the extracted value. A permissive inner operation such as `just` may return a different value, so each actual reflected candidate is authoritative when reconstructing the dependent generator.
                let innerResults = try reflectRecursive(inner, onFinalOutput: innerValue, context: context)
                return try innerResults.flatMap { innerResult in
                    let boundGenerator = try forward(innerResult.value)
                    let boundResults = try reflectRecursive(boundGenerator, onFinalOutput: finalOutput, context: context)
                    return boundResults.compactMap { boundResult -> (value: Any, path: [ChoiceTree])? in
                        guard structurallyEqual(boundResult.value, finalOutput) else {
                            return nil
                        }
                        let innerTree = innerResult.path.count == 1
                            ? innerResult.path[0]
                            : .group(innerResult.path)
                        let boundTree = boundResult.path.count == 1
                            ? boundResult.path[0]
                            : .group(boundResult.path)
                        return (
                            value: boundResult.value,
                            path: [.bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)]
                        )
                    }
                }
            case let .metamorphic(transforms, _):
                // Only the original is reflected; the supplied transformed members are never validated, so a stale tuple still reflects at the top level and replay regenerates its members. The length is checked because an array with any other count cannot be this node's output, and accepting one would let a pick probe select this arm for an array a sibling arm produced.
                guard let components = finalOutput as? [Any],
                      components.count == transforms.count + 1,
                      let original = components.first
                else {
                    throw ReflectionError.contramapWasWrongType
                }
                let reflectedResults = try reflectRecursive(inner, onFinalOutput: original, context: context)
                guard context.isProbingPickArm else {
                    return reflectedResults.map { result in
                        (value: components as Any, path: result.path)
                    }
                }
                // Inside a pick probe the reported value is what this node would produce from the reflected original, so the pick's comparison can tell this arm from a sibling that emits arrays of the same length. That is the one place the transforms run during reflection.
                return try reflectedResults.map { result in
                    var produced: [Any] = [result.value]
                    produced.reserveCapacity(transforms.count + 1)
                    for transform in transforms {
                        try produced.append(transform(result.value))
                    }
                    return (value: produced as Any, path: result.path)
                }
        }
    }
}
