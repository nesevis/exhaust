//
//  Reflect.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

// MARK: - Academic Provenance

//
// Implements the `reflect` interpretation (Goldstein §4.3.3, Fig 4.4). Backward pass that extracts choice sequences from concrete values by trying all possible decompositions. Exhaust extends reflection to handle six additional operations not in the dissertation: sequence, zip, just, filter, classify, and unique.

extension Interpreters {
    // MARK: - Public-Facing Reflect Function

    /// Finds the choice sequence that would cause `gen` to produce `outputValue`, performing the backward pass of the generator interpretation.
    ///
    /// Reflection is the inverse of ``generate(from:using:)``: given a concrete output value and a generator, it walks the generator structure in reverse to reconstruct the ``ChoiceTree`` whose forward interpretation would produce that value. Returns `nil` when the value cannot be decomposed through the generator's structure (for example, when a contramap backward function rejects the value or when a chooseBits value falls outside the declared range). The optional `check` closure filters results to only those whose output satisfies an additional predicate.
    ///
    /// - Parameters:
    ///   - gen: The generator to reflect through.
    ///   - outputValue: The target value to decompose into choices.
    ///   - check: An optional predicate that the reflected output must satisfy. Defaults to accepting all values.
    /// - Returns: A ``ChoiceTree`` encoding the choices that produce `outputValue`, or `nil` if no valid decomposition exists.
    /// - Throws: ``ReflectionError`` when the value is structurally incompatible with the generator.
    public static func reflect<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with outputValue: Output,
        // Optional validation check
        where check: (Output) -> Bool = { _ in true }
    ) throws -> ChoiceTree? {
        // The public API doesn't need to change. We start the process here.
        // We only care about the final output of the generator for the check.
        let allPossibleOutcomes = try reflectRecursive(gen, onFinalOutput: outputValue)

        let matchingPaths = allPossibleOutcomes.compactMap { outputValue, path -> [ChoiceTree]? in
            return check(outputValue) ? path : nil
        }.flatMap(\.self)

        switch matchingPaths.count {
        case 0:
            throw ReflectionError.couldNotMapInputToGenerator
        case 1:
            return matchingPaths[0]
        default:
            return .group(matchingPaths)
        }
    }

    // MARK: - Private Recursive Engine

    /// Reflects a target output value backward through a generator, reconstructing the choice tree path that produces it.
    ///
    /// Walks the ``FreerMonad`` spine in reverse: for `.pure`, returns the value directly; for `.impure`, calls ``interpretOperationBackward(_:onFinalOutput:outputType:)`` to determine which intermediate values could have produced the target, then recurses through the continuation for each candidate. The `finalOutput` is threaded unchanged through the entire recursion — each operation extracts its own intermediate from it.
    ///
    /// - Returns: All (value, path) pairs where the generator can produce `finalOutput`. Multiple results arise from non-injective pick operations.
    private static func reflectRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        onFinalOutput finalOutput: Any
    ) throws -> [(value: Output, path: [ChoiceTree])] {
        switch gen {
        case let .pure(value):
            // The pure value is the result for this path. No check needed here.
            return [(value, [])]

        case let .impure(operation, continuation):
            // 1. Interpret the operation against the final output value.
            let intermediateResults = try interpretOperationBackward(
                operation,
                onFinalOutput: finalOutput
            )

            // 2. For each successful intermediate result...
            return try intermediateResults.flatMap { (intermediateValue: Any, partialPath: [ChoiceTree]) in
                let nextGen = try continuation(intermediateValue)
                // The `finalOutput` is passed down UNCHANGED. This is the crucial part.
                let finalResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput)
                return finalResults.map { finalValue, restOfPath in
                    (finalValue, partialPath + restOfPath)
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
        onFinalOutput finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch op {
        // A nil onFinalOutput at this point means the generator produces an Optional type.
        case let .contramap(transform, nextGen):
            return try reflectContramapOperation(
                transform: transform,
                nextGen: nextGen,
                finalOutput: finalOutput
            )

        case let .prune(nextGen):
            return try reflectPruneOperation(nextGen: nextGen, finalOutput: finalOutput)

        case let .pick(choices, branchCount):
            return try reflectPickOperation(choices: choices, branchCount: branchCount, finalOutput: finalOutput)

        case let .chooseBits(min, max, tag, isRangeExplicit, _):
            return try reflectChooseBitsOperation(
                min: min,
                max: max,
                tag: tag,
                isRangeExplicit: isRangeExplicit,
                finalOutput: finalOutput
            )

        case let .just(value):
            // Avoid expensive string interpolation and prefix operations
            return [(value: value, path: [.just])]

        case .getSize:
            // We can't derive the `getSize` parameter when reflecting as it is normally used within a `bind`. However, `isRangeExplicit` on `.chooseBits` helps us determine whether to use the `min` and `max` on that case, or default to the fitting range according to the value's `BitPatternConvertible` conformance.
            var derivedSize: UInt64 = 0
            if let sequence = finalOutput as? any Sequence {
                derivedSize = UInt64(sequence.underestimatedCount)
            }
            // Store max size (100) so that replay and materialization see the full range for size-scaled generators.
            return [(value: derivedSize, path: [.getSize(100)])]

        case let .resize(newSize, nextGen):
            return try reflectResizeOperation(
                newSize: newSize,
                nextGen: nextGen,
                finalOutput: finalOutput
            )

        case let .sequence(lengthGen, elementGen):
            return try reflectSequenceOperation(
                lengthGen: lengthGen,
                elementGen: elementGen,
                finalOutput: finalOutput
            )

        case let .zip(generators, _):
            return try reflectZipOperation(generators: generators, finalOutput: finalOutput)

        case let .filter(gen, _, _, _, _, _):
            return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput)

        case let .classify(gen, _, _):
            return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput)

        case let .unique(gen, _, _):
            return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput)

        case let .transform(kind, inner):
            switch kind {
            case let .map(forward, inputType, outputType):
                if let inputBPC = inputType as? any BitPatternConvertible.Type,
                   let outputValue = finalOutput as? any BitPatternConvertible
                {
                    let inverted = inputBPC.init(bitPattern64: outputValue.bitPattern64)
                    do {
                        let roundTripped = try forward(inverted)
                        if let roundTrippedBPC = roundTripped as? any BitPatternConvertible,
                           roundTrippedBPC.bitPattern64 == outputValue.bitPattern64
                        {
                            let reflected = try reflectRecursive(inner, onFinalOutput: inverted)
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
            case let .bind(fingerprint, forward, backward, inputType, outputType):
                guard let backward else {
                    throw ReflectionError.forwardOnlyBind(
                        inputType: "\(inputType)",
                        outputType: "\(outputType)"
                    )
                }
                // Xia et al.'s comap at bind sites: extract the inner value from the final output.
                let innerValue = try backward(finalOutput)
                // Reconstruct the bound generator from the extracted inner value.
                let boundGen = try forward(innerValue)
                // Reflect both: inner against the extracted value, bound against the final output.
                let innerResults = try reflectRecursive(inner, onFinalOutput: innerValue)
                let boundResults = try reflectRecursive(boundGen, onFinalOutput: finalOutput)
                // Combine paths: inner choices followed by bound choices.
                return innerResults.flatMap { innerResult in
                    boundResults.map { boundResult in
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
            case .metamorphic:
                // The contramap backward already extracted the original Value from the output tuple. Reflect on inner with that value — the transforms are deterministic and will be re-derived on the forward pass.
                return try reflectRecursive(inner, onFinalOutput: finalOutput)
            }
        }
    }

    private static func reflectContramapOperation(
        transform: (Any) throws -> Any?,
        nextGen: ReflectiveGenerator<Any>,
        finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let subValue = try transform(finalOutput) else {
            throw ReflectionError.contramapWasWrongType
        }
        return try reflectRecursive(nextGen, onFinalOutput: subValue).map { ($0.value, $0.path) }
    }

    private static func reflectPruneOperation(
        nextGen: ReflectiveGenerator<Any>,
        finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        do {
            return try reflectRecursive(nextGen, onFinalOutput: finalOutput)
                .map { ($0.value, $0.path) }
        } catch ReflectionError.reflectedNil {
            return []
        }
    }

    private static func reflectPickOperation(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        branchCount: UInt64,
        finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let fingerprint = choices[0].fingerprint
        let results = try choices.flatMap { choice -> [(value: Any, fingerprint: UInt64, weight: UInt64, id: UInt64, isPicked: Bool, path: ChoiceTree)] in
            do {
                let reflectionPaths = try reflectRecursive(choice.generator, onFinalOutput: finalOutput)
                let value = reflectionPaths.firstNonNil(\.value)

                var isPicked = false
                if let equatableOutput = finalOutput as? any Equatable,
                   let equatableValue = value as? any Equatable
                {
                    isPicked = equatableOutput.isEqual(equatableValue)
                } else if let convertible = value as? any BitPatternConvertible {
                    isPicked = choice.generator.associatedRange?
                        .contains(convertible.bitPattern64) ?? false
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
                    throw error
                }
            }
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
        finalOutput: Any
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
            // Float types: allow NaN/infinity through so boundary coverage counterexamples are reflectable, but enforce the range for finite values.
            if tag.isFloatingPoint {
                let numericValue = tag.numericDoubleValue(forBitPattern: bitPattern)
                if numericValue.isFinite {
                    throw ReflectionError.inputWasOutOfGeneratorRange(
                        String(describing: convertibleValue),
                        min ... max
                    )
                }
            } else {
                throw ReflectionError.inputWasOutOfGeneratorRange(
                    String(describing: convertibleValue),
                    min ... max
                )
            }
        }

        let reflectedRange = isRangeExplicit
            ? min ... max
            : type(of: convertibleValue).bitPatternRange

        let metadata = ChoiceMetadata(
            validRange: reflectedRange,
            isRangeExplicit: isRangeExplicit
        )
        let choiceTree = ChoiceTree.choice(
            .init(convertibleValue, tag: tag),
            metadata
        )
        return [(value: convertibleValue, path: [choiceTree])]
    }

    private static func reflectResizeOperation(
        newSize: UInt64,
        nextGen: ReflectiveGenerator<Any>,
        finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let nestedResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput)
        return nestedResults.map { result in
            (value: result.value, path: [.resize(newSize: newSize, choices: result.path)])
        }
    }

    private static func reflectSequenceOperation(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let targetArray = finalOutput as? any Sequence else {
            throw ReflectionError.inputWasWrongForSequence("\(finalOutput)")
        }

        var combinedPath: [ChoiceTree] = []
        var combinedResults: [Any] = []

        let validRange: ClosedRange<UInt64>
        let isLengthRangeExplicit = lengthGen.associatedRange != nil
        if let lengthRange = lengthGen.associatedRange {
            validRange = lengthRange
        } else {
            let targetLength = UInt64(targetArray.underestimatedCount)
            let lengthReflection = try reflectRecursive(
                lengthGen,
                onFinalOutput: targetLength
            )
            validRange = lengthReflection
                .firstNonNil { $0.path.firstNonNil { $0.metadata.validRange } }
                ?? UInt64.bitPatternRange
        }

        for elementTarget in targetArray {
            let elementResults = try reflectRecursive(
                elementGen,
                onFinalOutput: elementTarget
            )
            guard let (value, path) = elementResults.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement("\(elementTarget)")
            }
            combinedResults.append(value)
            combinedPath.append(path.count == 1 ? path[0] : .group(path))
        }

        let finalTree = ChoiceTree.sequence(
            length: UInt64(targetArray.underestimatedCount),
            elements: combinedPath,
            ChoiceMetadata(validRange: validRange, isRangeExplicit: isLengthRangeExplicit)
        )
        return [(value: combinedResults, path: [finalTree])]
    }

    private static func reflectZipOperation(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let outputs = finalOutput as? [Any], outputs.count == generators.count else {
            throw ReflectionError.zipWasWrongLengthOrType
        }
        var results = [Any]()
        var paths = [ChoiceTree]()

        for (generator, output) in zip(generators, outputs) {
            let result = try Self.reflectRecursive(generator, onFinalOutput: output)
            let argPath = result.flatMap(\.path)
            if argPath.count == 1 {
                paths.append(argPath[0])
            } else {
                paths.append(.group(argPath))
            }
            results.append(contentsOf: result.map(\.value))
        }

        return [(value: results, path: [.group(paths)])]
    }

    private static func reflectPassthroughOperation(
        gen: ReflectiveGenerator<Any>,
        finalOutput: Any
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        try reflectRecursive(gen, onFinalOutput: finalOutput).map { ($0.value, $0.path) }
    }

    /// Errors thrown by the reflection interpreter when a value cannot be mapped back to its choice tree.
    public enum ReflectionError: LocalizedError, Equatable {
        /// Indicates that the target value is `nil` but the generator does not produce an optional type.
        case reflectedNil(type: String, resultType: String)
        /// Indicates that the contramap backward function received a value of unexpected type.
        case contramapWasWrongType
        /// Indicates that the zip target has wrong arity or element types for the declared generators.
        case zipWasWrongLengthOrType
        /// Indicates that none of the pick branches could produce a value matching the target.
        case couldNotMapInputToGenerator
        /// Indicates that the target value cannot be encoded as a bit pattern for the declared ``TypeTag``.
        case chooseBitsCouldNotConvertValue(String)
        /// Indicates that the target value for a sequence operation is not a valid collection.
        case inputWasWrongForSequence(String)
        /// Indicates that an individual element within a sequence could not be reflected through the element generator.
        case couldNotReflectOnSequenceElement(String)
        /// Indicates that a pick branch value lacks the ``Equatable`` conformance needed to match against the target.
        case pickValueIsNotEquatable(String)
        /// Indicates that the reflected bit pattern falls outside the declared chooseBits range.
        case inputWasOutOfGeneratorRange(String, ClosedRange<UInt64>)
        /// Reflection failed because a forward-only `map` was detected.
        /// Use `.mapped(forward:backward:)` instead to enable bidirectional operation.
        case forwardOnlyMap(inputType: String, outputType: String)
        /// Reflection failed because a forward-only `bind` was detected.
        case forwardOnlyBind(inputType: String, outputType: String)
        /// Reflection failed because a metamorphic transform was detected.
        /// Metamorph transforms are forward-only and cannot be reflected backward.
        case forwardOnlyMetamorph

        public var errorDescription: String? {
            switch self {
            case let .forwardOnlyMap(inputType, outputType):
                "Reflection failed — forward-only map (\(inputType) → \(outputType)) detected. Consider using .mapped(forward:backward:) instead."
            case let .forwardOnlyBind(inputType, outputType):
                "Reflection failed — forward-only bind (\(inputType) → \(outputType)) detected."
            case .forwardOnlyMetamorph:
                "Reflection failed — metamorphic transforms are forward-only and cannot be reflected backward."
            default:
                nil
            }
        }
    }
}
