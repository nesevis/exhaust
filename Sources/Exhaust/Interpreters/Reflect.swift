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
        
        return .group(matchingPaths)
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
//            // LMAP's JOB: Try to cast the final output to its expected Input type.
//            guard let typedFinalOutput = finalOutput as? Output else {
//                return [] // This path is impossible if the types don't align.
//            }
//            // "Zoom in": Apply the transform to create a new, local target for the sub-generator.
//            let inputValue = transform(typedFinalOutput)
//            if let convertible = inputValue as? any BitPatternConvertible {
//                return [(inputValue, [.choice(convertible.bitPattern64)])]
//            }
//            return []
//            return reflectRecursive(nextGen, onFinalOutput: inputValue).map { ($0.value, $0.path) }

        case let .prune(nextGen):
            // PRUNE's JOB: Try to cast the final output to an Optional and check if it's nil.
            guard let optionalTarget = .some(finalOutput as Optional<Any>), let wrappedTarget = optionalTarget else {
                return [] // Pruned!
            }
            return reflectRecursive(nextGen, onFinalOutput: wrappedTarget).map { ($0.value, $0.path) }

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
                convertibleValue = convertible.underestimatedCount
            }
            guard let convertibleValue else {
                return []
            }
            let bitPattern = convertibleValue.bitPattern64
            guard (min...max).contains(bitPattern) else {
                return []
            }
            
            // Success! The result for the continuation is the value itself.
            return [(value: finalOutput, path: [.choice(bitPattern)])]
        case let .sequence(length, gen):
            // 1. The target value for a sequence MUST be an array.
            guard
                let targetArray = ((finalOutput as? [Any]) ?? (Array((finalOutput as? String) ?? "") as? [Any])),
                targetArray.count == Int(length)
            else {
                return []
            }
            
            var combinedPath: [ChoiceTree] = []
            var combinedResults: [Any] = []
            var validRange: ClosedRange<UInt64>?
            
            // 3. Iterate over the elements of the target array.
            for elementTarget in targetArray {
                // Reflect on the element generator with the corresponding element as the target.
                // We assume reflection on an element is non-ambiguous and produces one path.
                guard let (value, path) = self.reflectRecursive(gen, onFinalOutput: elementTarget).first else {
                    // If any element cannot be reflected, the whole sequence fails.
                    return []
                }
                combinedResults.append(value)
                combinedPath.append(contentsOf: path)
                if validRange == nil, let convertible = value as? any BitPatternConvertible {
                    validRange = type(of: convertible).bitPatternRange
                }
            }
            let finalTree = ChoiceTree.sequence(length: length, elements: combinedPath, validRange: validRange ?? UInt64.bitPatternRange)
            return [(value: combinedResults, path: [finalTree])]
        }
    }
}
