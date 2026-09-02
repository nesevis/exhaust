//
//  Reflect.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

// MARK: - Academic Background

//
// Implements the `reflect` interpretation (Goldstein section 4.3.3, Fig 4.4). Backward pass that extracts choice sequences from concrete values by trying all possible decompositions. Exhaust extends reflection to handle six additional operations not in the dissertation: sequence, zip, just, filter, classify, and unique.

extension Interpreters {
    // MARK: - Public-Facing Reflect Function

    /// Finds the choice sequence that would cause `gen` to produce `outputValue`, performing the backward pass of the generator interpretation.
    ///
    /// Reflection is the inverse of the forward generation pass: given a concrete output value and a generator, it walks the generator structure in reverse to reconstruct the ``ChoiceTree`` whose forward interpretation would produce that value. Returns `nil` when the value cannot be decomposed through the generator's structure (for example, when a contramap backward function rejects the value or when a chooseBits value falls outside the declared range). The optional `check` closure filters results to only those whose output satisfies an additional predicate.
    ///
    /// - Parameters:
    ///   - gen: The generator to reflect through.
    ///   - outputValue: The target value to decompose into choices.
    ///   - check: An optional predicate that the reflected output must satisfy. Defaults to accepting all values.
    /// - Returns: A ``ChoiceTree`` encoding the choices that produce `outputValue`, or `nil` if no valid decomposition exists.
    /// - Throws: ``ReflectionError`` when the value is structurally incompatible with the generator.
    public static func reflect<Output>(
        _ gen: Generator<Output>,
        with outputValue: Output,
        // Optional validation check
        where check: (Output) -> Bool = { _ in true }
    ) throws -> ChoiceTree? {
        // The public API doesn't need to change. We start the process here.
        // We only care about the final output of the generator for the check.
        let allPossibleOutcomes = try reflectRecursive(gen, onFinalOutput: outputValue, probingPickArm: false)

        let matchingPaths = allPossibleOutcomes.compactMap { outputValue, path -> [ChoiceTree]? in
            return check(outputValue) ? path : nil
        }.flatMap { $0 }

        switch matchingPaths.count {
            case 0:
                return nil
            case 1:
                return matchingPaths[0]
            default:
                return .group(matchingPaths)
        }
    }

    // MARK: - Component-Replacing Reflection

    /// Reflects `parent` through a zip-shaped generator with one component swapped, returning the choice tree that produces the modified value, or nil when `gen` is not a zip-shaped reflective generator or the swap cannot be reflected.
    ///
    /// A composite built by `#gen(a, b, c) { Foo(a, b, c) }` reflects as `contramap*→zip`. The map adds no choices, so the zip's component subtrees are the whole choice tree. Recovering the parent's component tuple, replacing component `index`, and reflecting the zip against the modified tuple yields the sequence that materializes to `Foo` with that field retargeted and the rest preserved. The value type is never reconstructed: `Mirror` is read-only, so the `[Any]` component tuple is the only generically mutable representation, which is why the swap happens there rather than on the value.
    ///
    /// - Parameters:
    ///   - gen: A zip-shaped reflective generator (`contramap*→zip`); any other shape returns nil.
    ///   - parent: The scaffold value supplying every component but the replaced one.
    ///   - index: The component to replace.
    ///   - replacement: Given the parent's component, whose runtime type is the field type, returns its replacement or nil to reject the graft.
    /// - Returns: The choice tree for the modified value, or nil on any miss.
    package static func reflectReplacingZipComponent<Output>(
        _ gen: Generator<Output>,
        parent: Output,
        index: Int,
        replacement: (Any) -> Any?
    ) throws -> ChoiceTree? {
        guard let (children, components) = locateZip(gen.erase(), value: parent) else {
            return nil
        }
        guard components.indices.contains(index),
              let newComponent = replacement(components[index])
        else {
            return nil
        }
        var modified = components
        modified[index] = newComponent
        let results = try reflectZipOperation(generators: children, finalOutput: modified, probingPickArm: false)
        guard let path = results.first?.path, path.count == 1 else {
            return nil
        }
        return path[0]
    }

    /// Grafts a harvested comparison operand into one field of `parent` and reflects the retargeted composite, or nil when the field cannot take the operand.
    ///
    /// Composes ``reflectReplacingZipComponent(_:parent:index:replacement:)`` with the reconstructor selected from the field's runtime type: the operand's bytes are decoded as the field's own type through ``OperandReconstruction/erasedReconstructor(for:)``, so no per-type closure is written and the whole path is driven by the operand word alone. This is the decision the injection loop makes for one draw; keeping it here, rather than inline in the runner, lets it be exercised with a literal operand word standing in for the trace-cmp comparand.
    ///
    /// - Parameters:
    ///   - gen: A zip-shaped reflective generator (`contramap*→zip`).
    ///   - parent: The scaffold value supplying every field but the grafted one.
    ///   - index: The field to retarget.
    ///   - operand: The harvested comparison operand.
    /// - Returns: The choice tree for the retargeted value, or nil on any miss.
    package static func reflectGraftingOperand<Output>(
        into gen: Generator<Output>,
        parent: Output,
        index: Int,
        operand: UInt64
    ) throws -> ChoiceTree? {
        try reflectReplacingZipComponent(gen, parent: parent, index: index) { component in
            guard let reconstruct = OperandReconstruction.erasedReconstructor(for: type(of: component)) else {
                return nil
            }
            return reconstruct(operand)
        }
    }

    /// Whether `gen` is a zip-shaped generator the field graft can target: a `zip` reachable through only the choice-free, invertible wrappers (`contramap`, `prune`, and the `isomorph` or bidirectional-`map` `transform`). Structural only — it does not apply the backward transforms, so it needs no value and is meant to be computed once at construction to gate the graft, sparing a non-composite generator the parent materialization the graft would otherwise run before discovering it cannot reflect.
    package static func isZipShaped(_ gen: Generator<some Any>) -> Bool {
        structurallyReachesZip(gen.erase())
    }

    private static func structurallyReachesZip(_ gen: AnyGenerator) -> Bool {
        guard case let .impure(operation, _) = gen else {
            return false
        }
        switch operation {
            case let .contramap(_, next):
                return structurallyReachesZip(next)
            case let .prune(next):
                return structurallyReachesZip(next)
            case let .transform(kind, inner):
                switch kind {
                    case .isomorph:
                        return structurallyReachesZip(inner)
                    case let .map(_, backward, _, _):
                        return backward != nil && structurallyReachesZip(inner)
                    default:
                        return false
                }
            case .zip:
                return true
            default:
                return false
        }
    }

    /// Descends the choice-free layers wrapping a `zip` — `contramap`, `prune`, and the invertible `transform` (`isomorph` and bidirectional `map`) that `Gen.zip` and an initializer-shaped `#gen` emit — to the zip itself, applying each layer's backward function to `value` so the returned tuple is the zip's own `[Any]` input. `Gen.zip` wraps its `[Any]` payload in an `isomorph`; a `#gen(a, b, c) { Foo(...) }` adds a bidirectional `map` above that, so a struct reaches the zip through two transform layers. Returns nil at a forward-only `map`, any other operation, a `.pure` terminal, or when a backward function rejects the value.
    private static func locateZip(
        _ gen: AnyGenerator,
        value: Any
    ) -> (children: ContiguousArray<AnyGenerator>, components: [Any])? {
        guard case let .impure(operation, _) = gen else {
            return nil
        }
        switch operation {
            case let .contramap(transform, next):
                guard let narrowed = try? transform(value) else {
                    return nil
                }
                return locateZip(next, value: narrowed)
            case let .prune(next):
                return locateZip(next, value: value)
            case let .transform(kind, inner):
                switch kind {
                    case let .isomorph(_, backward, _, _):
                        guard let innerValue = try? backward(value) else {
                            return nil
                        }
                        return locateZip(inner, value: innerValue)
                    case let .map(_, backward?, _, _):
                        guard let innerValue = try? backward(value) else {
                            return nil
                        }
                        return locateZip(inner, value: innerValue)
                    default:
                        return nil
                }
            case let .zip(generators, _):
                guard let components = value as? [Any], components.count == generators.count else {
                    return nil
                }
                return (generators, components)
            default:
                return nil
        }
    }

    // MARK: - Private Recursive Engine

    /// Reflects a target output value backward through a generator, reconstructing the choice tree path that produces it.
    ///
    /// Walks the ``FreerMonad`` spine in reverse: for `.pure`, returns the value directly; for `.impure`, calls ``interpretOperationBackward(_:onFinalOutput:outputType:)`` to determine which intermediate values could have produced the target, then recurses through the continuation for each candidate. The `finalOutput` is threaded unchanged through the entire recursion — each operation extracts its own intermediate from it.
    ///
    /// `probingPickArm` is true while reflecting inside a pick arm, where a node's reported value decides which arm the pick selects. Nodes whose reported value would otherwise echo the target unchanged (`metamorphic`) rebuild it from the reflected original there, and only there, so top-level reflection keeps its contract of never running user transforms.
    ///
    /// - Returns: The reflected value and its path when the generator can produce `finalOutput`, or an empty array when it cannot.
    private static func reflectRecursive<Output>(
        _ gen: Generator<Output>,
        onFinalOutput finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Output, path: [ChoiceTree])] {
        switch gen {
            case let .pure(value):
                // The pure value is the result for this path. No check needed here.
                return [(value, [])]

            case let .impure(operation, continuation):
                // 1. Interpret the operation against the final output value.
                let intermediateResults = try interpretOperationBackward(
                    operation,
                    onFinalOutput: finalOutput,
                    probingPickArm: probingPickArm
                )

                // 2. For each successful intermediate result...
                return try intermediateResults.flatMap { (intermediateValue: Any, partialPath: [ChoiceTree]) in
                    let nextGen = try continuation(intermediateValue)
                    // The `finalOutput` is passed down UNCHANGED. This is the crucial part.
                    let finalResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput, probingPickArm: probingPickArm)
                    return finalResults.compactMap { finalValue, restOfPath in
                        (finalValue as? Output).map { (value: $0, path: partialPath + restOfPath) }
                    }
                }
        }
    }

    // MARK: - Backward Interpreter for Individual Operations

    /// Interprets a single ``ReflectiveOperation`` in the backward direction, producing candidate intermediate values and partial choice tree paths.
    ///
    /// For chooseBits: inverts the bit-pattern encoding to recover the original value. For pick: tries each branch's sub-generator via ``reflectRecursive`` and returns the branch whose output matches `finalOutput`. For sequence: reflects each element independently. For contramap: applies the backward transform to extract the inner value from `finalOutput`.
    private static func interpretOperationBackward(
        _ op: ReflectiveOperation,
        onFinalOutput finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch op {
            // A nil onFinalOutput at this point means the generator produces an Optional type.
            case let .contramap(transform, nextGen):
                return try reflectContramapOperation(
                    transform: transform,
                    nextGen: nextGen,
                    finalOutput: finalOutput,
                    probingPickArm: probingPickArm
                )

            case let .prune(nextGen):
                return try reflectPruneOperation(nextGen: nextGen, finalOutput: finalOutput, probingPickArm: probingPickArm)

            case let .pick(choices, _):
                return try reflectPickOperation(choices: choices, finalOutput: finalOutput, probingPickArm: probingPickArm)

            case let .chooseBits(min, max, tag, isRangeExplicit, _, typeTagPayload):
                return try reflectChooseBitsOperation(
                    min: min,
                    max: max,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    typeTagPayload: typeTagPayload,
                    finalOutput: finalOutput,
                    probingPickArm: probingPickArm
                )

            case let .just(value):
                // Avoid expensive string interpolation and prefix operations
                return [(value: value, path: [.just])]

            case .getSize:
                // We can't derive the `getSize` parameter when reflecting as it is normally used within a `bind`. However, `isRangeExplicit` on `.chooseBits` helps us determine whether to use the `min` and `max` on that case, or default to the fitting range according to the value's `BitPatternConvertible` conformance.
                let derivedSize: UInt64 = switch finalOutput {
                    case let size as UInt64:
                        size
                    case let sequence as any Sequence:
                        UInt64(sequence.underestimatedCount)
                    default:
                        0
                }
                // Store max size (100) so that replay and materialization see the full range for size-scaled generators.
                return [(value: derivedSize, path: [.getSize(100)])]

            case let .resize(newSize, nextGen):
                return try reflectResizeOperation(
                    newSize: newSize,
                    nextGen: nextGen,
                    finalOutput: finalOutput,
                    probingPickArm: probingPickArm
                )

            case let .sequence(lengthGen, elementGen, _):
                return try reflectSequenceOperation(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    finalOutput: finalOutput,
                    probingPickArm: probingPickArm
                )

            case let .zip(generators, _):
                return try reflectZipOperation(generators: generators, finalOutput: finalOutput, probingPickArm: probingPickArm)

            case let .filter(gen, _, _, _, _):
                return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput, probingPickArm: probingPickArm)

            case let .classify(gen, _, _):
                return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput, probingPickArm: probingPickArm)

            case let .unique(gen, _, _):
                return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput, probingPickArm: probingPickArm)

            case let .transform(kind, inner):
                return try reflectTransformOperation(kind: kind, inner: inner, finalOutput: finalOutput, probingPickArm: probingPickArm)
        }
    }

    private static func reflectContramapOperation(
        transform: (Any) throws -> Any?,
        nextGen: AnyGenerator,
        finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let subValue = try transform(finalOutput) else {
            throw ReflectionError.contramapWasWrongType
        }
        return try reflectRecursive(nextGen, onFinalOutput: subValue, probingPickArm: probingPickArm).map { ($0.value, $0.path) }
    }

    private static func reflectPruneOperation(
        nextGen: AnyGenerator,
        finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        do {
            return try reflectRecursive(nextGen, onFinalOutput: finalOutput, probingPickArm: probingPickArm)
                .map { ($0.value, $0.path) }
        } catch ReflectionError.reflectedNil {
            return []
        } catch ReflectionError.contramapWasWrongType {
            return []
        }
    }

    private static func reflectPickOperation(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        finalOutput: Any,
        probingPickArm _: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let branchCount = UInt64(choices.count)
        let fingerprint = choices[0].fingerprint
        var deferredBranchError: ReflectionError?
        let results = try choices.flatMap { choice -> [(value: Any, fingerprint: UInt64, weight: UInt64, id: UInt64, isPicked: Bool, path: ChoiceTree)] in
            do {
                let reflectionPaths = try reflectRecursive(choice.generator, onFinalOutput: finalOutput, probingPickArm: true)
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
                        guard let path = pathTree.first else { continue }
                        results.append((value, fingerprint, choice.weight, choice.id, true, path))
                    }
                }
                return results

            } catch let error as ReflectionError {
                switch error {
                    case .reflectedNil, .inputWasOutOfGeneratorRange, .contramapWasWrongType:
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
        if results.isEmpty, let deferredBranchError {
            throw deferredBranchError
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

    private static func reflectChooseBitsOperation(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        typeTagPayload: TypeTagPayload?,
        finalOutput: Any,
        probingPickArm _: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        var convertibleValue: (any BitPatternConvertible)?
        if let convertible = finalOutput as? any BitPatternConvertible {
            convertibleValue = convertible
        }
        if let convertible = finalOutput as? any Sequence {
            convertibleValue = UInt64(convertible.underestimatedCount)
        }
        guard let convertibleValue else {
            throw ReflectionError.chooseBitsCouldNotConvertValue("\(finalOutput)")
        }

        let bitPattern = convertibleValue.bitPattern64
        if isRangeExplicit, (min ... max).contains(bitPattern) == false {
            // Float types: allow NaN/infinity through so problematic-value screening counterexamples are reflectable, but enforce the range for finite values.
            let range = ChoiceValue(bitPattern, tag: tag).displayRange(min ... max)
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
            ? min ... max
            : type(of: convertibleValue).bitPatternRange

        let metadata = ChoiceMetadata(
            validRange: reflectedRange,
            isRangeExplicit: isRangeExplicit,
            typeTagPayload: typeTagPayload
        )
        let choiceTree = ChoiceTree.choice(
            .init(convertibleValue, tag: tag),
            metadata
        )
        return [(value: convertibleValue, path: [choiceTree])]
    }

    private static func reflectResizeOperation(
        newSize: UInt64,
        nextGen: AnyGenerator,
        finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let nestedResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput, probingPickArm: probingPickArm)
        return nestedResults.map { result in
            (value: result.value, path: [.resize(newSize: newSize, choices: result.path)])
        }
    }

    private static func reflectSequenceOperation(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let targetArray = finalOutput as? any Sequence else {
            throw ReflectionError.inputWasWrongForSequence("\(finalOutput)")
        }

        var combinedPath: [ChoiceTree] = []
        var combinedResults: [Any] = []

        let isLengthRangeExplicit = lengthGen.associatedRange != nil

        for elementTarget in targetArray {
            let elementResults = try reflectRecursive(elementGen, onFinalOutput: elementTarget, probingPickArm: probingPickArm)
            guard let (value, path) = elementResults.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement("\(elementTarget)")
            }
            combinedResults.append(value)
            combinedPath.append(path.count == 1 ? path[0] : .group(path))
        }

        let validRange: ClosedRange<UInt64>
        if let lengthRange = lengthGen.associatedRange {
            validRange = lengthRange
        } else {
            let targetLength = UInt64(combinedPath.count)
            let lengthReflection = try reflectRecursive(lengthGen, onFinalOutput: targetLength, probingPickArm: probingPickArm)
            validRange = lengthReflection
                .firstNonNil { $0.path.firstNonNil { $0.metadata.validRange } }
                ?? UInt64.bitPatternRange
        }

        let finalTree = ChoiceTree.sequence(
            elements: combinedPath,
            metadata: ChoiceMetadata(
                validRange: validRange,
                isRangeExplicit: isLengthRangeExplicit
            )
        )
        return [(value: combinedResults, path: [finalTree])]
    }

    private static func reflectZipOperation(
        generators: ContiguousArray<AnyGenerator>,
        finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let outputs = finalOutput as? [Any], outputs.count == generators.count else {
            throw ReflectionError.zipWasWrongLengthOrType
        }
        var results = [Any]()
        var paths = [ChoiceTree]()

        for (generator, output) in zip(generators, outputs) {
            let candidates = try Self.reflectRecursive(generator, onFinalOutput: output, probingPickArm: probingPickArm)
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
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        try reflectRecursive(gen, onFinalOutput: finalOutput, probingPickArm: probingPickArm).map { ($0.value, $0.path) }
    }

    private static func reflectTransformOperation(
        kind: TransformKind,
        inner: AnyGenerator,
        finalOutput: Any,
        probingPickArm: Bool
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch kind {
            case let .map(forward, backward, inputType, outputType):
                if let backward {
                    // Bidirectional map (`mapped(forward:backward:)`): apply the user-contract inverse, reflect the inner generator against the recovered input, then reconstruct the mapped value for upstream matching.
                    let innerValue = try backward(finalOutput)
                    let reflected = try reflectRecursive(inner, onFinalOutput: innerValue, probingPickArm: probingPickArm)
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
                            let reflected = try reflectRecursive(inner, onFinalOutput: inverted, probingPickArm: probingPickArm)
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
                let reflected = try reflectRecursive(inner, onFinalOutput: innerValue, probingPickArm: probingPickArm)
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
                let innerResults = try reflectRecursive(inner, onFinalOutput: innerValue, probingPickArm: probingPickArm)
                return try innerResults.flatMap { innerResult in
                    let boundGenerator = try forward(innerResult.value)
                    let boundResults = try reflectRecursive(boundGenerator, onFinalOutput: finalOutput, probingPickArm: probingPickArm)
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
                let reflectedResults = try reflectRecursive(inner, onFinalOutput: original, probingPickArm: probingPickArm)
                guard probingPickArm else {
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
