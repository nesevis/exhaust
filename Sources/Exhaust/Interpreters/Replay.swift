//
//  Replay.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

extension Interpreters {
    // ... `generate` and `reflect` and their helpers ...

    // MARK: - Public-Facing Replay Function
    
    /// Deterministically reproduces a value by executing a generator with a given choice path.
    ///
    /// This function is the inverse of `reflect`. It is essential for test-case shrinking
    /// and for perfectly reproducing test failures.
    ///
    /// - Parameters:
    ///   - gen: The generator to execute.
    ///   - choicePath: An array of strings, typically the output of a `reflect` call.
    /// - Returns: The deterministically generated value, or `nil` if the path is invalid
    ///   or doesn't match the generator's structure.
    public static func replay<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        using choicePath: [String]
    ) -> Output? {
        // Start the recursive process with the full choice path.
        let result = replayRecursive(gen, choicePath: choicePath)
        
        // A successful replay should consume the entire path. If there are leftover
        // choices, it means the path was longer than the generator's needs.
        guard let (value, remainingChoices) = result, remainingChoices.isEmpty else {
            return nil
        }
        
        return value
    }

    // MARK: - Private Recursive Replay Engine
    
    /// The recursive engine that consumes the generator and the choice path.
    ///
    /// - Returns: A tuple containing the generated value and the array of choices that
    ///   were *not* consumed. This allows parent calls to continue consuming the script.
    private static func replayRecursive<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        choicePath: [String]
    ) -> (value: Output, remainingChoices: [String])? {
        
        switch gen {
        case .pure(let value):
            // Base case: we've produced a value. Return it along with the unconsumed path.
            return (value, choicePath)

        case .impure(let operation, let continuation):
            // This helper simplifies calling the continuation with a result and the remaining path.
            let runContinuation = { (result: Any, remainingPath: [String]) -> (Output, [String])? in
                let nextGen = continuation(result)
                return self.replayRecursive(nextGen, choicePath: remainingPath)
            }
            
            switch operation {
                
            case .pick(let choices):
                // Consume the next choice from the script to decide which branch to take.
                guard !choicePath.isEmpty else { return nil } // Path ended prematurely.
                let choiceLabel = choicePath.first!
                let remainingPath = Array(choicePath.dropFirst())
                
                // Find the sub-generator that matches the label.
                guard let chosenGen = choices.first(where: { $0.choice == choiceLabel })?.generator else {
                    return nil // Invalid choice label in path.
                }
                
                // Recursively replay the chosen sub-generator with the rest of the script.
                guard let result = self.replayRecursive(chosenGen, choicePath: remainingPath) else { return nil }
                return runContinuation(result.value, result.remainingChoices)

            case .chooseBits:
                // Consume the next choice and interpret it as the raw bits.
                guard !choicePath.isEmpty else { return nil }
                let bitsString = choicePath.first!
                let remainingPath = Array(choicePath.dropFirst())
                
                guard let bits = UInt64(bitsString) else { return nil } // Invalid bit string in path.
                
                // The "result" of this operation is the bits. The continuation will decode it.
                return runContinuation(bits, remainingPath)

            case .lens(_, let subGenerator):
                // A `.lens` operation's purpose is to guide reflection. In the forward
                // replay pass, it doesn't consume a choice from the path itself.
                // The choices are consumed by the `subGenerator` that produces the value.
                // We just need to execute the sub-generator and pass its result to the continuation.
                guard let result = self.replayRecursive(subGenerator, choicePath: choicePath) else { return nil }
                return runContinuation(result.value, result.remainingChoices)

            // Forward-only operations do not consume choices.
            case .getSize:
                return runContinuation(10, choicePath) // Provide a default size.
            case .resize(_, let nextGen):
                guard let result = self.replayRecursive(nextGen, choicePath: choicePath) else { return nil }
                return runContinuation(result.value, result.remainingChoices)
                
            // from/biFrom do not consume choices. Their logic is deterministic based on input,
            // which is not part of the replay model. This highlights a slight architectural mismatch.
            // A pure replay model would not have `from`. If we keep it, it's a no-op here.
            case .lmap, .prune:
                fatalError("Replay for this operation is not yet implemented or is invalid in a pure replay context.")
            }
        }
    }
}
