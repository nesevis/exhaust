//
//  Replay.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

extension Interpreters {
    // ... `generate` and `reflect` and their helpers ...

    /// MARK: - Public-Facing Replay Function
    
    /// Deterministically reproduces a value by executing a generator with a structured `ChoiceTree`.
    ///
    /// - Parameters:
    ///   - gen: The generator to execute.
    ///   - choiceTree: The structured script of choices to follow.
    /// - Returns: The deterministically generated value, or `nil` if the tree does not
    ///   match the generator's structure.
    public static func replay<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        using choiceTree: ChoiceTree
    ) -> Output? {
        // Start the recursive process. The helper returns the value and any *unconsumed*
        // parts of the tree. A successful top-level replay should consume the entire tree.
        let result = replayRecursive(gen, with: choiceTree)
        
        // We can add a check here to ensure no parts of the tree were left over,
        // but the recursive logic should handle this correctly.
        return result
    }

    // MARK: - Private Recursive Replay Engine
    
    private static func replayRecursive<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        with script: ChoiceTree
    ) -> Output? {
        
        switch gen {
        case .pure(let value):
            // Base case: The generator is done. Return the final value.
            // Any remaining script would indicate a mismatch, but the logic
            // for the calling operation handles passing the correct sub-tree.
            return value

        case .impure(let operation, let continuation):
            // This helper simplifies calling the continuation with a result.
            let runContinuation = { (result: Any) -> Output? in
                // The crucial difference: we are NOT passing the script down.
                // The continuation represents the rest of the generator, which
                // will be handled by the next level of the .impure case.
                let nextGen = continuation(result)
                // We replay the rest of the generator with the *same* script,
                // as the operation itself doesn't consume the whole tree.
                return self.replayRecursive(nextGen, with: script)
            }
            
            // This is the core structural match. We switch on the operation.
            switch operation {
                
            case .chooseBits:
                // This operation expects a primitive `.choice` node from the script.
                guard case .choice(let stringValue) = script,
                      let bits = UInt64(stringValue) else { return nil }
                
                return runContinuation(bits)

            case .pick(let choices):
                // This operation expects a `.branch` node from the script.
                guard case .branch(let label, let children) = script else { return nil }
                
                // Find the sub-generator that matches the label from the script.
                guard let chosenGen = choices.first(where: { $0.choice == label })?.generator else { return nil }
                
                // Recursively replay the chosen sub-generator with the children of this branch node.
                // A group of children is replayed as a single unit.
                let childScript = ChoiceTree.group(children)
                return self.replayRecursive(chosenGen, with: childScript) as? Output

            case .sequence(let count, let elementGenerator):
                // This operation expects a `.sequence` node from the script.
                guard case .sequence(let length, let elements) = script else { return nil }
                
                // The counts must match.
                guard count == length else { return nil }
                
                var accumulatedValues: [Any] = []
                for elementScript in elements {
                    // Replay each element with its corresponding sub-tree from the script.
                    guard let elementValue = self.replayRecursive(elementGenerator, with: elementScript) else {
                        return nil // Fail if any element fails to replay.
                    }
                    accumulatedValues.append(elementValue)
                }
                
                return runContinuation(accumulatedValues)

            case .lens(_, let subGenerator):
                 // A lens is a wrapper. It doesn't consume a node from the script itself.
                 // The choices are consumed by its sub-generator. We pass the same script down.
                return self.replayRecursive(subGenerator, with: script) as? Output
                
//            case .group(let children) where operation is ReflectiveOperation<Any>.group: // Fictitious .group op for this to work
//                 // When replaying a group, we must consume it.
//                 guard case .group(let scriptChildren) = script, children.count == scriptChildren.count else { return nil }
//                 
//                 var results = []
//                 for (i, childGen) in children.enumerated() {
//                     results.append(replayRecursive(childGen, with: scriptChildren[i]))
//                 }
//                 return runContinuation(results)
                 
            // Forward-only ops don't consume choices. Their presence in a reflectable
            // generator is an error.
            default:
                fatalError("Cannot replay a generator containing forward-only operations like getSize or from.")
            }
        }
    }
}
