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
        _ gen: ReflectiveGenerator<Input, Output>,
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
    
    private static func replayWithChoices<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
        choices: [ChoiceTree]
    ) -> Output? {
        var remainingChoices = choices
        return replayWithChoicesHelper(gen, choices: &remainingChoices)
    }
    
    private static func replayWithChoicesHelper<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
        choices: inout [ChoiceTree]
    ) -> Output? {
        
        switch gen {
        case let .pure(value):
            // Base case: return the value
            return value

        case let .impure(operation, continuation):
            // Handle each operation by consuming appropriate choices
            switch operation {
                
            case .chooseBits:
                // Consume the next choice
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case let .choice(bits) = choice else { return nil }
                
                let nextGen = continuation(bits)
                return self.replayWithChoicesHelper(nextGen, choices: &choices)

            case let .pick(pickChoices):
                // Consume the next choice which should be a branch
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case let .branch(label, children) = choice else { return nil }
                
                // Find the sub-generator that matches the label
                guard let chosenGen = pickChoices.first(where: { $0.label == label })?.generator else { return nil }
                
                // Process the chosen sub-generator with its children
                guard let result = replayWithChoices(chosenGen, choices: children) else { return nil }
                
                let nextGen = continuation(result)
                return self.replayWithChoicesHelper(nextGen, choices: &choices)

            case let .sequence(count, elementGenerator):
                // Consume the next choice which should be a sequence
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case let .sequence(length, elements, range) = choice else { return nil }
                
                var accumulatedValues: [Any] = []
                for elementScript in elements {
                    guard let elementValue = self.replayRecursive(elementGenerator, with: elementScript) else {
                        return nil
                    }
                    accumulatedValues.append(elementValue)
                }
                
                let nextGen = continuation(accumulatedValues)
                return self.replayWithChoicesHelper(nextGen, choices: &choices)

            case let .lmap(_, subGenerator), let .prune(subGenerator):
                // A left map or prune doesn't consume choices, just passes them to the sub-generator
                guard let subResult = self.replayWithChoicesHelper(subGenerator, choices: &choices) else {
                    return nil
                }
                let nextGen = continuation(subResult)
                return self.replayWithChoicesHelper(nextGen, choices: &choices)
            }
        }
    }
    
    private static func replayRecursive<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
        with script: ChoiceTree
    ) -> Output? {
        
        // Handle group scripts by distributing choices to the generator
        if case let .group(choices) = script {
            return replayWithChoices(gen, choices: choices)
        }
        
        switch gen {
        case let .pure(value):
            // Base case: The generator is done. Return the final value.
            // Any remaining script would indicate a mismatch, but the logic
            // for the calling operation handles passing the correct sub-tree.
            return value

        case let .impure(operation, continuation):
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
                guard case let .choice(bits) = script else {
                    return nil
                }
                return runContinuation(bits)

            case let .pick(choices):
                // This operation expects a `.branch` node from the script.
                guard case .branch(let label, let children) = script else { return nil }
                
                // Find the sub-generator that matches the label from the script.
                guard let chosenGen = choices.first(where: { $0.label == label })?.generator else { return nil }
                
                // Recursively replay the chosen sub-generator with the children of this branch node.
                // A group of children is replayed as a single unit.
                let childScript = ChoiceTree.group(children)
                guard let result = self.replayRecursive(chosenGen, with: childScript) else { return nil }
                return result as? Output

            case let .sequence(lengthGen, elementGenerator):
                // This operation expects a `.sequence` node from the script.
                guard case let .sequence(length, elements, _) = script else { return nil }
                
                guard let count = self.replayRecursive(lengthGen, with: .choice(length)) else {
                    return nil
                }
                
                var accumulatedValues: [Any] = []
                for elementScript in elements {
                    // Replay each element with its corresponding sub-tree from the script.
                    guard let elementValue = self.replayRecursive(elementGenerator, with: elementScript) else {
                        return nil // Fail if any element fails to replay.
                    }
                    accumulatedValues.append(elementValue)
                }
                
                return runContinuation(accumulatedValues)
                 
            // Forward-only ops don't consume choices. Their presence in a reflectable
            // generator is an error.
            case let .lmap(_, subGenerator):
                // A lens/lmap is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let subResult = self.replayRecursive(subGenerator, with: script) else { return nil }
                
                // Call the continuation with the subResult to handle the transformation
                let nextGen = continuation(subResult)
                return self.replayRecursive(nextGen, with: script)
                
            case let .prune(subGenerator):
                // A prune is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let result = self.replayRecursive(subGenerator, with: script) else { return nil }
                return result as? Output
            }
        }
    }
}
