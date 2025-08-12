//
//  Reflector.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

public extension Interpreters {
    // MARK: - Public-Facing Reflect Function (Unchanged, but now correct)

    static func reflect<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with outputValue: Output,
        /// Optional validation check
        where check: (Output) -> Bool = { _ in true }
    ) throws -> ChoiceTree? {
        // The public API doesn't need to change. We start the process here.
        // We only care about the final output of the generator for the check.
        let allPossibleOutcomes = try reflectRecursive(gen, onFinalOutput: outputValue)
        
        let matchingPaths = allPossibleOutcomes.compactMap { (outputValue, path) -> [ChoiceTree]? in
            return check(outputValue) ? path : nil
        }.flatMap { $0 }

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
        onFinalOutput finalOutput: Any
    ) throws -> [(value: Output, path: [ChoiceTree])] { // Still returns typed Output and path
        switch gen {
        case let .pure(value):
            // The pure value is the result for this path. No check needed here.
            return [(value, [])]

        case let .impure(operation, continuation):
            // 1. Interpret the operation against the final output value.
            let intermediateResults = try interpretOperationBackward(operation, onFinalOutput: finalOutput, outputType: Output.self)
            
            // 2. For each successful intermediate result...
            let results = try intermediateResults.flatMap { (intermediateValue: Any, partialPath: [ChoiceTree]) in
                let nextGen = try continuation(intermediateValue)
                // The `finalOutput` is passed down UNCHANGED. This is the crucial part.
                let finalResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput)
                return finalResults.map { (finalValue, restOfPath) in
                    (finalValue, partialPath + restOfPath)
                }
            }
            return results
        }
    }
    
    // MARK: - Backward Interpreter for Individual Operations

    /// This helper interprets a single operation. It receives the overall final output
    /// and determines what to do based on its own semantics.
    private static func interpretOperationBackward<Output>(
        _ op: ReflectiveOperation,
        onFinalOutput finalOutput: Any,
        outputType: Output.Type
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch op {
        // If the `onFinalOutput` is nil here, it must be an optional. How do we handle that?
        case let .lmap(transform, nextGen):
            guard let subValue = try transform(finalOutput) else {
                throw ReflectionError.lmapWasWrongType
            }
            return try reflectRecursive(nextGen, onFinalOutput: subValue)
                .map { ($0.value, $0.path) }
            
        case let .prune(nextGen):
            do {
                return try reflectRecursive(nextGen, onFinalOutput: finalOutput).map { ($0.value, $0.path) }
            } catch ReflectionError.reflectedNil {
                return []
            }

        case let .pick(choices):
            // PICK's JOB: Try all branches against the same final output value.
            let results = try choices.flatMap { (_, label, generator) -> [(value: Any, label: UInt64,  isPicked: Bool, path: [ChoiceTree])] in
                do {
                    let subPaths = try reflectRecursive(generator, onFinalOutput: finalOutput)
                    let value = subPaths.firstNonNil(\.value)
                    
                    var isPicked = false
                    if
                        let equatableOutput = finalOutput as? any Equatable,
                        let equatableValue = value as? any Equatable
                    {
                        // Try to compare using Equatable
                        isPicked = equatableOutput.isEqual(equatableValue)
                    } else if let convertible = value as? any BitPatternConvertible {
                        isPicked = generator.associatedRange?.contains(convertible.bitPattern64) ?? false
                    }
                    
                    let labeledPaths = subPaths.map { (value, pathTree) in
                        (value, label, isPicked, pathTree)
                    }
                    return labeledPaths
                    
                } catch ReflectionError.reflectedNil {
                    // Return the choice anyway; we want all branches materialised during reflection
                    return [(value: finalOutput, label: label, isPicked: false, path: [])]
                }
            }
            let returnData = results.map {
                let branch = ChoiceTree.branch(label: $0.label, children: $0.path)
                return (value: $0.value, path: $0.isPicked ? .selected(branch) : branch)
            }
            return [(finalOutput, [ChoiceTree.group(returnData.map(\.1))])]

        case let .chooseBits(min, max, tag):
            var convertibleValue: (any BitPatternConvertible)?
            // In the reverse pass of a [[Char]] we'll be passed the array here and it will represent the length of the list. How can we know that?
            if let convertible = finalOutput as? any BitPatternConvertible {
                convertibleValue = convertible
            }
            // This is awful. What about triply nested arrays?
            if let convertible = finalOutput as? any Sequence {
                // Due to the mapping on Ints, this number's bitPattern64 will be an outrageously high number.
                convertibleValue = UInt64(convertible.underestimatedCount)
            }
            guard let convertibleValue else {
                throw ReflectionError.chooseBitsCouldNotConvertValue("\(finalOutput)")
            }
            // Success! The result for the continuation is the value itself.
            let metadata = ChoiceMetadata(
                // We can't know the proper range here, and the min...max is _usually_ dependent on the getSize parameter
                validRanges: [min...max],
                // FIXME: We can clamp this here as well using the range
                strategies: [
                    FundamentalReducerStrategy(direction: .towardsLowerBound),
                    BoundaryReducerStrategy(direction: .towardsLowerBound),
//                    SpreadReducerStrategy(direction: .towardsLowerBound),
                    BinaryReducerStrategy(direction: .towardsLowerBound),
                    SaturationReducerStrategy(direction: .towardsLowerBound)
                ]
            )
            return [(value: finalOutput, path: [.choice(.init(convertibleValue, tag: tag), metadata)])]
        
        case let .just(value):
            // Avoid expensive string interpolation and prefix operations
            return [(value: value, path: [.just("\(value)")])]
            
        case .getSize:
            // FIXME We can't derive the getSize parameter when reflecting as the bind continuation that applies it is opaque to us. Ultimately it shouldn't matter for replay
            // But it does for reflection.
            var derivedSize: UInt64 = 0
            if let sequence = finalOutput as? any Sequence {
                derivedSize = UInt64(sequence.underestimatedCount)
            }
            // For replay
            return [(value: derivedSize, path: [.getSize(0)])]
            
        case let .resize(newSize, nextGen):
            // For resize, reflect on the nested generator with the new size context
            let nestedResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput)
            
            return nestedResults.map { result in
                (value: result.value, path: [.resize(newSize: newSize, choices: result.path)])
            }
            
        case let .sequence(lengthGen, elementGen):
            // 1. The target value for a sequence MUST be an array.
            guard
                let targetArray = finalOutput as? any Sequence
            else {
                throw ReflectionError.inputWasWrongForSequence("\(finalOutput)")
            }
            
            var combinedPath: [ChoiceTree] = []
            var combinedResults: [Any] = []
            
            // FIXME: Make less allocaty
            var validRanges = [ClosedRange<UInt64>]()
            if let lengthRange = lengthGen.associatedRange {
                validRanges = [lengthRange]
            } else {
                let lengthReflection = try reflectRecursive(lengthGen, onFinalOutput: finalOutput)
                validRanges = [lengthReflection.firstNonNil({ $0.path.firstNonNil { $0.metadata.validRanges.first }}) ?? UInt64.bitPatternRanges[0]]
            }
            
            // 3. Iterate over the elements of the target array.
            for elementTarget in targetArray {
                // Reflect on the element generator with the corresponding element as the target.
                // We assume reflection on an element is non-ambiguous and produces one path.
                guard let (value, path) = try reflectRecursive(elementGen, onFinalOutput: elementTarget).first else {
                    // If any element cannot be reflected, the whole sequence fails.
                    throw ReflectionError.couldNotReflectOnSequenceElement("\(elementTarget)")
                }
                combinedResults.append(value)
                // Group each element's path choices instead of flattening them
                if path.count == 1 {
                    combinedPath.append(path[0])
                } else {
                    combinedPath.append(.group(path))
                }
            }
            
            let metadata = ChoiceMetadata(
                validRanges: validRanges,
                strategies: ShrinkingStrategy.sequenceStrategies
            )
            let finalTree = ChoiceTree.sequence(
                // When replaying, the length should match the array count. Any number of transformations could lead to a change here??
                length: UInt64(targetArray.underestimatedCount),
//                length: lengthResult.first?.value ?? 0,
                elements: combinedPath,
                metadata
            )
            return [(value: combinedResults, path: [finalTree])]
        case let .zip(generators):
            guard
                let outputs = finalOutput as? [Any],
                outputs.count == generators.count
            else {
                throw ReflectionError.zipWasWrongLengthOrType
            }
            var results = [Any]()
            var paths = [ChoiceTree]()

            for (generator, output) in zip(generators, outputs) {
                let result = try Self.reflectRecursive(generator, onFinalOutput: output)
                paths.append(contentsOf: [.group(result.flatMap(\.path))])
                results.append(contentsOf: result.map(\.value))
            }
            return [(value: results, path: [.group(paths)])]
        }
    }
    
    enum ReflectionError: LocalizedError {
        case reflectedNil(type: String)
        case lmapWasWrongType
        case zipWasWrongLengthOrType
        case couldNotMapInputToGenerator
        case chooseBitsCouldNotConvertValue(String)
        case inputWasWrongForSequence(String)
        case couldNotReflectOnSequenceElement(String)
        case pickValueIsNotEquatable(String)
        case inputWasOutOfGeneratorRange(any BitPatternConvertible, ClosedRange<UInt64>)
    }
}
