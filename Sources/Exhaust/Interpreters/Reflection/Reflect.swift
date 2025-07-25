//
//  Reflector.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

extension Interpreters {
    // MARK: - Public-Facing Reflect Function (Unchanged, but now correct)

    public static func reflect<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
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

    // MARK: - Private Recursive Engine (Signature is Key)

    /// The main recursive engine for reflection.
    /// It now takes the *final output value* as a constant target throughout the recursion.
    private static func reflectRecursive<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
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
                let nextGen = continuation(intermediateValue)
                // The `finalOutput` is passed down UNCHANGED. This is the crucial part.
                let finalResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput)
                return finalResults.map { (finalValue, restOfPath) in
                    (finalValue, partialPath + restOfPath)
                }
            }
            return results
        }
    }
    
    // MARK: - Backward Interpreter for Individual Operations (Corrected Logic)

    /// This helper interprets a single operation. It receives the overall final output
    /// and determines what to do based on its own semantics.
    private static func interpretOperationBackward<Input, Output>(
        _ op: ReflectiveOperation<Input>,
        onFinalOutput finalOutput: Any,
        outputType: Output.Type
    ) throws -> [(value: Any, path: [ChoiceTree])] {
        switch op {
        case let .lmap(transform, nextGen):
            guard let subValue = transform(finalOutput) else {
                throw ReflectionError.lmapWasWrongType
            }
            return try reflectRecursive(nextGen, onFinalOutput: subValue)
                .map { ($0.value, $0.path) }
            
        case let .prune(nextGen):
            // PRUNE's JOB: Check if the final output is nil and should be pruned.
            // When case path extraction fails on wrong enum cases, it produces nil wrapped in Optional<Any>
            // This needs to be filtered out to prevent invalid branches in reflection recipes
            if let optionalValue = finalOutput as? Optional<Any>, optionalValue == nil {
                return [] // Prune nil values from failed case path extractions
            }
            
            return try reflectRecursive(nextGen, onFinalOutput: finalOutput).map { ($0.value, $0.path) }

        case let .pick(choices):
            // PICK's JOB: Try all branches against the same final output value.
            let results = try choices.flatMap { (_, label, generator) -> [(value: Any, label: UInt64,  isPicked: Bool, path: [ChoiceTree])] in
                let subPaths = try reflectRecursive(generator, onFinalOutput: finalOutput)
                // The reflection process creates a history of the choices made to create that value,
                // so we prune the choices to find the one that was made. This requires `Gen.pick` to
                // require Equatable-conforming values.
                // FIXME: The open question is how the shrinker deals with this "lack" of choice?
                guard
                    let equatableOutput = finalOutput as? any Equatable,
                    let equatableValue = subPaths.firstNonNil({ $0.value as? any Equatable })
                else {
                    throw ReflectionError.pickValueIsNotEquatable("\(finalOutput)")
                }
                
                let isPicked = equatableValue.isEqual(equatableOutput)
                
                let labeledPaths = subPaths.map { (value, pathTree) in
                    (value, label, isPicked, pathTree)
                }
                return labeledPaths
            }
            let returnData = results.map {
                let branch = ChoiceTree.branch(label: $0.label, children: $0.path)
                return (value: $0.value, path: $0.isPicked ? .selected(branch) : branch)
            }
            return [(finalOutput, [ChoiceTree.group(returnData.map(\.1))])]
            
        case let .chooseBits(min, max):
            // In the reverse pass of a [[Char]] we'll be passed the array here and it will represent the length of the list. How can we know that?
            var convertibleValue: (any BitPatternConvertible)?
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
            let bitPattern = convertibleValue.bitPattern64
            guard (min...max).contains(bitPattern) else {
                throw ReflectionError.inputWasOutOfGeneratorRange(convertibleValue, min...max)
            }
            
            // Success! The result for the continuation is the value itself.
            let metadata = ChoiceMetadata(
                validRanges: op.associatedRange.map { [$0] } ?? type(of: convertibleValue).bitPatternRanges,
                // FIXME: We can clamp this here as well using the range
                strategies: [
                    FundamentalReducerStrategy(direction: .towardsLowerBound),
                    BoundaryReducerStrategy(direction: .towardsLowerBound),
                    SpreadReducerStrategy(direction: .towardsLowerBound),
                    BinaryReducerStrategy(direction: .towardsLowerBound),
                    SaturationReducerStrategy(direction: .towardsLowerBound)
                ]
            )
            return [(value: finalOutput, path: [.choice(.init(convertibleValue), metadata)])]
        
        case let .chooseCharacter(min, max):
            // Handle Character-specific reflection
            guard let character = finalOutput as? Character else {
                return []
            }
            // Validate that the character is within the expected range
            let firstScalar = character.unicodeScalars.first?.value ?? 0
            guard (min...max).contains(UInt64(firstScalar)) else {
                throw ReflectionError.inputWasOutOfGeneratorRange(character, min...max)
            }
            
            // Store the exact Character representation
            let metadata = ChoiceMetadata(
                validRanges: [min...max], // Character uses the provided range directly
                // FIXME: We can clamp this here as well using the range
                strategies: [
                    FundamentalReducerStrategy(direction: .towardsLowerBound),
                    BoundaryReducerStrategy(direction: .towardsLowerBound),
                    SpreadReducerStrategy(direction: .towardsLowerBound),
                    BinaryReducerStrategy(direction: .towardsLowerBound),
                    SaturationReducerStrategy(direction: .towardsLowerBound)
                ]
            )
            return [(value: finalOutput, path: [.choice(.init(character), metadata)])]
        
        case let .just(value):
            let string = "\(value)".prefix(50)
            return [(value: value, path: [.just(String(string))])]
        case let .sequence(lengthGen, elementGen):
            // 1. The target value for a sequence MUST be an array.
            guard
                let targetArray = finalOutput as? any Sequence
            else {
                throw ReflectionError.inputWasWrongForSequence("\(finalOutput)")
            }
            
            var combinedPath: [ChoiceTree] = []
            var combinedResults: [Any] = []
            let validRanges = lengthGen.associatedRange.map { [$0] }
            
            let lengthResult = try reflectRecursive(lengthGen, onFinalOutput: finalOutput)
            
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
                validRanges: validRanges ?? UInt64.bitPatternRanges,
                strategies: ShrinkingStrategy.sequenceStrategies
            )
            let finalTree = ChoiceTree.sequence(
                length: lengthResult.first?.value ?? 0,
                elements: combinedPath,
                metadata
            )
            return [(value: combinedResults, path: [finalTree])]
        }
    }
    
    enum ReflectionError: LocalizedError {
        case lmapWasWrongType
        case couldNotMapInputToGenerator
        case chooseBitsCouldNotConvertValue(String)
        case inputWasWrongForSequence(String)
        case couldNotReflectOnSequenceElement(String)
        case pickValueIsNotEquatable(String)
        case inputWasOutOfGeneratorRange(any BitPatternConvertible, ClosedRange<UInt64>)
    }
}
