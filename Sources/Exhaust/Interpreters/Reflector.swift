//
//  Reflector.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

extension Interpreters {
    // MARK: - Public-Facing Reflect Function (Unchanged, but now correct)

    public static func reflect<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        with outputValue: Output,
        /// Optional validation check
        where check: (Output) -> Bool = { _ in true }
    ) -> [[String]] {
        // The public API doesn't need to change. We start the process here.
        // We only care about the final output of the generator for the check.
        let allPossibleOutcomes = reflectRecursive(gen, onFinalOutput: outputValue)
        
        let matchingPaths = allPossibleOutcomes.compactMap { (outputValue, path) -> [String]? in
            return check(outputValue) ? path : nil
        }
        
        return matchingPaths
    }

    // MARK: - Private Recursive Engine (Signature is Key)

    /// The main recursive engine for reflection.
    /// It now takes the *final output value* as a constant target throughout the recursion.
    private static func reflectRecursive<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        onFinalOutput finalOutput: Any
    ) -> [(value: Output, path: [String])] { // Still returns typed Output and path
        switch gen {
        case .pure(let value):
            // The pure value is the result for this path. No check needed here.
            return [(value, [])]

        case .impure(let operation, let continuation):
            // 1. Interpret the operation against the final output value.
            let intermediateResults = interpretOperationBackward(operation, onFinalOutput: finalOutput)
            
            // 2. For each successful intermediate result...
            let results = intermediateResults.flatMap { (intermediateValue: Any, partialPath: [String]) in
                let nextGen = continuation(intermediateValue)
                // The `finalOutput` is passed down UNCHANGED. This is the crucial part.
                let finalResults = reflectRecursive(nextGen, onFinalOutput: finalOutput)
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
    private static func interpretOperationBackward<Input>(
        _ op: ReflectiveOperation<Input>,
        onFinalOutput finalOutput: Any
    ) -> [(resultForContinuation: Any, path: [String])] {
        switch op {
        case .lmap(let transform, let nextGen):
            // LMAP's JOB: Try to cast the final output to its expected Input type.
            guard let typedFinalOutput = finalOutput as? Input else {
                return [] // This path is impossible if the types don't align.
            }
            // "Zoom in": Apply the transform to create a new, local target for the sub-generator.
            let nextTarget = transform(typedFinalOutput)
            return reflectRecursive(nextGen, onFinalOutput: nextTarget).map { ($0.value, $0.path) }

        case .prune(let nextGen):
            // PRUNE's JOB: Try to cast the final output to an Optional and check if it's nil.
            guard let optionalTarget = .some(finalOutput as Optional<Any>), let wrappedTarget = optionalTarget else {
                return [] // Pruned!
            }
            return reflectRecursive(nextGen, onFinalOutput: wrappedTarget).map { ($0.value, $0.path) }

        case .pick(let choices):
            // PICK's JOB: Try all branches against the same final output value.
            return choices.flatMap { (_, label, generator) -> [(resultForContinuation: Any, path: [String])] in
                let subPaths = reflectRecursive(generator, onFinalOutput: finalOutput)
                return subPaths.map { (value, path) in
                    (value, (label.map { [$0] } ?? []) + path)
                }
            }
        case let .lens(path, next):
            guard let subValue = path.extract(from: finalOutput) else {
                return []
            }
            return reflectRecursive(next, onFinalOutput: subValue)
                .map { ($0.value, $0.path) }
        case .chooseBits(let min, let max):
            // CHOOSE's JOB: Try to cast the final output to a comparable primitive.
            // Kolbu We have an instance of the output here, but we don't know what part of the output object this generator corresponds to
            guard let convertibleValue = finalOutput as? any BitPatternConvertible else {
                return []
            }
            let bitPattern = convertibleValue.bitPattern64
            guard (min...max).contains(bitPattern) else {
                return []
            }
            
            // Success! The result for the continuation is the value itself.
            return [(resultForContinuation: finalOutput, path: [bitPattern.description])]
        case .getSize, .resize:
            fatalError("Should not be included!")
        }
    }
}
