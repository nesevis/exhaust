//
//  Reflect.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

public enum Interpreters {
    // MARK: - Public-Facing Reflect Function (Unchanged, but now correct)

    public static func reflect<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with outputValue: Output,
        // Optional validation check
        where check: (Output) -> Bool = { _ in true },
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

    /// The main recursive engine for reflection.
    /// It now takes the *final output value* as a constant target throughout the recursion.
    private static func reflectRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        onFinalOutput finalOutput: Any,
    ) throws -> [(value: Output, path: [ChoiceTree])] { // Still returns typed Output and path
        switch gen {
        case let .pure(value):
            // The pure value is the result for this path. No check needed here.
            return [(value, [])]

        case let .impure(operation, continuation):
            // 1. Interpret the operation against the final output value.
            let intermediateResults = try interpretOperationBackward(operation, onFinalOutput: finalOutput, outputType: Output.self)

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

    /// This helper interprets a single operation. It receives the overall final output
    /// and determines what to do based on its own semantics.
    private static func interpretOperationBackward(
        _ op: ReflectiveOperation,
        onFinalOutput finalOutput: Any,
        outputType _: (some Any).Type,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch op {
        // If the `onFinalOutput` is nil here, it must be an optional. How do we handle that?
        case let .contramap(transform, nextGen):
            return try reflectContramapOperation(
                transform: transform,
                nextGen: nextGen,
                finalOutput: finalOutput,
            )

        case let .prune(nextGen):
            return try reflectPruneOperation(nextGen: nextGen, finalOutput: finalOutput)

        case let .pick(choices):
            return try reflectPickOperation(choices: choices, finalOutput: finalOutput)

        case let .chooseBits(min, max, tag, isRangeExplicit):
            return try reflectChooseBitsOperation(
                min: min,
                max: max,
                tag: tag,
                isRangeExplicit: isRangeExplicit,
                finalOutput: finalOutput,
            )

        case let .just(value):
            // Avoid expensive string interpolation and prefix operations
            return [(value: value, path: [.just("\(value)")])]

        case .getSize:
            // We can't derive the `getSize` parameter when reflecting as it is normally used within a `bind`. However, `isRangeExplicit` on `.chooseBits` helps us determine whether to use the `min` and `max` on that case, or default to the fitting range according to the value's `BitPatternConvertible` conformance.
            var derivedSize: UInt64 = 0
            if let sequence = finalOutput as? any Sequence {
                derivedSize = UInt64(sequence.underestimatedCount)
            }
            // For replay
            return [(value: derivedSize, path: [.getSize(0)])]

        case let .resize(newSize, nextGen):
            return try reflectResizeOperation(
                newSize: newSize,
                nextGen: nextGen,
                finalOutput: finalOutput,
            )

        case let .sequence(lengthGen, elementGen):
            return try reflectSequenceOperation(
                lengthGen: lengthGen,
                elementGen: elementGen,
                finalOutput: finalOutput,
            )

        case let .zip(generators):
            return try reflectZipOperation(generators: generators, finalOutput: finalOutput)

        case let .filter(gen, _, _):
            return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput)

        case let .classify(gen, _, _):
            return try reflectPassthroughOperation(gen: gen, finalOutput: finalOutput)
        }
    }

    @inline(__always)
    private static func reflectContramapOperation(
        transform: (Any) throws -> Any?,
        nextGen: ReflectiveGenerator<Any>,
        finalOutput: Any,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let subValue = try transform(finalOutput) else {
            throw ReflectionError.contramapWasWrongType
        }
        return try reflectRecursive(nextGen, onFinalOutput: subValue).map { ($0.value, $0.path) }
    }

    @inline(__always)
    private static func reflectPruneOperation(
        nextGen: ReflectiveGenerator<Any>,
        finalOutput: Any,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        do {
            return try reflectRecursive(nextGen, onFinalOutput: finalOutput).map { ($0.value, $0.path) }
        } catch ReflectionError.reflectedNil {
            return []
        }
    }

    private static func reflectPickOperation(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        finalOutput: Any,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let branchIDs = choices.map(\.id)
        let results = try choices.flatMap { choice -> [(value: Any, weight: UInt64, id: UInt64, isPicked: Bool, path: ChoiceTree)] in
            do {
                let subPaths = try reflectRecursive(choice.generator, onFinalOutput: finalOutput)
                let value = subPaths.firstNonNil(\.value)

                var isPicked = false
                if let equatableOutput = finalOutput as? any Equatable,
                   let equatableValue = value as? any Equatable
                {
                    isPicked = equatableOutput.isEqual(equatableValue)
                } else if let convertible = value as? any BitPatternConvertible {
                    isPicked = choice.generator.associatedRange?.contains(convertible.bitPattern64) ?? false
                }

                return subPaths
                    .compactMap { value, pathTree in
                        guard let path = pathTree.first else {
                            return nil
                        }
                        return (value, choice.weight, choice.id, isPicked, path)
                    }
                    .filter { $0.isPicked }

            } catch let error as ReflectionError {
                switch error {
                case .reflectedNil, .inputWasOutOfGeneratorRange:
                    return []
                default:
                    throw error
                }
            }
        }

        let mappedBranches = results.map {
            let branch = ChoiceTree.branch(
                weight: $0.weight,
                id: $0.id,
                branchIDs: branchIDs,
                choice: $0.path,
            )
            return $0.isPicked ? ChoiceTree.selected(branch) : branch
        }
        return [(finalOutput, [ChoiceTree.group(mappedBranches)])]
    }

    private static func reflectChooseBitsOperation(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        finalOutput: Any,
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
            throw ReflectionError.inputWasOutOfGeneratorRange(convertibleValue, min ... max)
        }

        let reflectedRanges: [ClosedRange<UInt64>]
        if isRangeExplicit {
            reflectedRanges = [min ... max]
        } else {
            let fallbackRange = type(of: convertibleValue).bitPatternRanges
                .first(where: { $0.contains(bitPattern) }) ?? (UInt64.min ... UInt64.max)
            reflectedRanges = [fallbackRange]
        }

        let metadata = ChoiceMetadata(validRanges: reflectedRanges)
        return [(value: finalOutput, path: [.choice(.init(convertibleValue, tag: tag), metadata)])]
    }

    @inline(__always)
    private static func reflectResizeOperation(
        newSize: UInt64,
        nextGen: ReflectiveGenerator<Any>,
        finalOutput: Any,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        let nestedResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput)
        return nestedResults.map { result in
            (value: result.value, path: [.resize(newSize: newSize, choices: result.path)])
        }
    }

    private static func reflectSequenceOperation(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        finalOutput: Any,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let targetArray = finalOutput as? any Sequence else {
            throw ReflectionError.inputWasWrongForSequence("\(finalOutput)")
        }

        var combinedPath: [ChoiceTree] = []
        var combinedResults: [Any] = []

        let validRanges: [ClosedRange<UInt64>]
        if let lengthRange = lengthGen.associatedRange {
            validRanges = [lengthRange]
        } else {
            let lengthReflection = try reflectRecursive(lengthGen, onFinalOutput: finalOutput)
            let range = lengthReflection.firstNonNil { $0.path.firstNonNil { $0.metadata.validRanges.first } }
                ?? UInt64.bitPatternRanges[0]
            validRanges = [range]
        }

        for elementTarget in targetArray {
            guard let (value, path) = try reflectRecursive(elementGen, onFinalOutput: elementTarget).first else {
                throw ReflectionError.couldNotReflectOnSequenceElement("\(elementTarget)")
            }
            combinedResults.append(value)
            combinedPath.append(path.count == 1 ? path[0] : .group(path))
        }

        let finalTree = ChoiceTree.sequence(
            length: UInt64(targetArray.underestimatedCount),
            elements: combinedPath,
            ChoiceMetadata(validRanges: validRanges),
        )
        return [(value: combinedResults, path: [finalTree])]
    }

    private static func reflectZipOperation(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        finalOutput: Any,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        guard let outputs = finalOutput as? [Any], outputs.count == generators.count else {
            throw ReflectionError.zipWasWrongLengthOrType
        }
        var results = [Any]()
        var paths = [ChoiceTree]()

        for (generator, output) in zip(generators, outputs) {
            let result = try Self.reflectRecursive(generator, onFinalOutput: output)
            paths.append(.group(result.flatMap(\.path)))
            results.append(contentsOf: result.map(\.value))
        }
        return [(value: results, path: [.group(paths)])]
    }

    @inline(__always)
    private static func reflectPassthroughOperation(
        gen: ReflectiveGenerator<Any>,
        finalOutput: Any,
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        try reflectRecursive(gen, onFinalOutput: finalOutput).map { ($0.value, $0.path) }
    }

    public enum ReflectionError: LocalizedError {
        case reflectedNil(type: String, resultType: String)
        case contramapWasWrongType
        case zipWasWrongLengthOrType
        case couldNotMapInputToGenerator
        case chooseBitsCouldNotConvertValue(String)
        case inputWasWrongForSequence(String)
        case couldNotReflectOnSequenceElement(String)
        case pickValueIsNotEquatable(String)
        case inputWasOutOfGeneratorRange(any BitPatternConvertible, ClosedRange<UInt64>)
    }
}
