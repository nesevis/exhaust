//
//  Reflector.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

extension Interpreters {
    // MARK: - Public-Facing Reflect Function (Unchanged, but now correct)

    public static func reflect<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
        with outputValue: Output,
        /// Optional validation check
        where check: (Output) -> Bool = { _ in true }
    ) -> ChoiceTree? {
        // The public API doesn't need to change. We start the process here.
        // We only care about the final output of the generator for the check.
        let allPossibleOutcomes = reflectRecursive(gen, onFinalOutput: outputValue)
        
        let matchingPaths = allPossibleOutcomes.compactMap { (outputValue, path) -> [ChoiceTree]? in
            return check(outputValue) ? path : nil
        }.flatMap { $0 }
        
        guard matchingPaths.isEmpty == false else {
            return nil
        }
        switch matchingPaths.count {
        case 0:
            return nil
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
    ) -> [(value: Output, path: [ChoiceTree])] { // Still returns typed Output and path
        switch gen {
        case let .pure(value):
            // The pure value is the result for this path. No check needed here.
            return [(value, [])]

        case let .impure(operation, continuation):
            // 1. Interpret the operation against the final output value.
            let intermediateResults = interpretOperationBackward(operation, onFinalOutput: finalOutput, outputType: Output.self)
            
            // 2. For each successful intermediate result...
            let results = intermediateResults.flatMap { (intermediateValue: Any, partialPath: [ChoiceTree]) in
                if case .lmap = operation, false {
                    // Do not execute the continuation
                    return [(value: finalOutput as! Output, path: partialPath)]
                } else {
                    let nextGen = continuation(intermediateValue)
                    // The `finalOutput` is passed down UNCHANGED. This is the crucial part.
                    let finalResults = reflectRecursive(nextGen, onFinalOutput: finalOutput)
                    return finalResults.map { (finalValue, restOfPath) in
                        (finalValue, partialPath + restOfPath)
                    }
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
    ) -> [(value: Any, path: [ChoiceTree])] {
        switch op {
        case let .lmap(transform, nextGen):
            guard let subValue = transform(finalOutput) else {
                return []
            }
            return reflectRecursive(nextGen, onFinalOutput: subValue)
                .map { ($0.value, $0.path) }
            
        case let .prune(nextGen):
            // PRUNE's JOB: Check if the final output is nil and should be pruned.
            // When case path extraction fails on wrong enum cases, it produces nil wrapped in Optional<Any>
            // This needs to be filtered out to prevent invalid branches in reflection recipes
            if let optionalValue = finalOutput as? Optional<Any>, optionalValue == nil {
                return [] // Prune nil values from failed case path extractions
            }
            
            return reflectRecursive(nextGen, onFinalOutput: finalOutput).map { ($0.value, $0.path) }

        case let .pick(choices):
            // PICK's JOB: Try all branches against the same final output value.
            return choices.flatMap { (_, label, generator) -> [(value: Any, path: [ChoiceTree])] in
                let subPaths = reflectRecursive(generator, onFinalOutput: finalOutput)
                let labeledPaths = subPaths.map { (value, pathTree) in
                    (value, [ChoiceTree.branch(label: label, children: pathTree)])
                }
                return labeledPaths
            }
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
                return []
            }
            let bitPattern = convertibleValue.bitPattern64
            guard (min...max).contains(bitPattern) else {
                return []
            }
            
            // Success! The result for the continuation is the value itself.
            let metadata = ChoiceMetadata(
                validRanges: [type(of: convertibleValue).bitPatternRange],
                strategies: (type(of: convertibleValue) as? any Arbitrary.Type)?.strategies ?? []
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
                return []
            }
            
            // Store the exact Character representation
            let metadata = ChoiceMetadata(
                validRanges: [min...max], // Character uses the provided range directly
                strategies: Character.strategies
            )
            return [(value: finalOutput, path: [.choice(.init(character), metadata)])]
        
        case let .just(value):
            return [(value: value, path: [.just])]
        case let .sequence(lengthGen, elementGen):
            // 1. The target value for a sequence MUST be an array.
            guard
                let targetArray = finalOutput as? any Sequence
            else {
                return []
            }
            
            var combinedPath: [ChoiceTree] = []
            var combinedResults: [Any] = []
            var validRange: ClosedRange<UInt64>?
            
//            let length = UInt64(5)
            let lengthResult = self.reflectRecursive(lengthGen, onFinalOutput: finalOutput)
            
            // 3. Iterate over the elements of the target array.
            for elementTarget in targetArray {
                // Reflect on the element generator with the corresponding element as the target.
                // We assume reflection on an element is non-ambiguous and produces one path.
                guard let (value, path) = self.reflectRecursive(elementGen, onFinalOutput: elementTarget).first else {
                    // If any element cannot be reflected, the whole sequence fails.
                    return []
                }
                combinedResults.append(value)
                // Group each element's path choices instead of flattening them
                if path.count == 1 {
                    combinedPath.append(path[0])
                } else {
                    combinedPath.append(.group(path))
                }
                if validRange == nil, let convertible = value as? any BitPatternConvertible {
                    validRange = type(of: convertible).bitPatternRange
                }
            }
            
            let metadata = ChoiceMetadata(
                validRanges: [validRange ?? UInt64.bitPatternRange],
                strategies: .sequences // For sequences, use the sequences strategies
            )
            let finalTree = ChoiceTree.sequence(
                length: lengthResult.first?.value ?? 0,
                elements: combinedPath,
                metadata
            )
            return [(value: combinedResults, path: [finalTree])]
        }
    }
}
