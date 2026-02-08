//
//  Replay.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

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
    public static func replay<Output>(
        _ gen: ReflectiveGenerator<Output>,
        using choiceTree: ChoiceTree
    ) throws -> Output? {
        // First let's unwrap any `.important` markers
        let unwrappedChoice = choiceTree.map { choice in
            if case let .important(choiceTree) = choice {
                // FIXME: Why is it wrapped in important twice?!
                if case let .important(wrappedTwice) = choiceTree {
                    return wrappedTwice
                }
                return choiceTree
            }
            return choice
        }
        // Start the recursive process. The helper returns the value and any *unconsumed*
        // parts of the tree. A successful top-level replay should consume the entire tree.
        let result = try replayRecursive(gen, with: unwrappedChoice)
        
        // We can add a check here to ensure no parts of the tree were left over,
        // but the recursive logic should handle this correctly.
        return result
    }

    // MARK: - Private Recursive Replay Engine
    
    private static func replayWithChoices<Output>(
        _ gen: ReflectiveGenerator<Output>,
        choices: [ChoiceTree]
    ) throws -> Output? {
        var remainingChoices = choices
        return try replayWithChoicesHelper(gen, choices: &remainingChoices)
    }
    
    private static func replayWithChoicesHelper<Output>(
        _ gen: ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree]
    ) throws -> Output? {
        switch gen {
        case let .pure(value):
            // Base case: return the value
            return value

        case let .impure(operation, continuation):
            // Handle each operation by consuming appropriate choices
            switch operation {
                
            case .chooseBits:
                // Consume the next choice
                guard !choices.isEmpty else {
                    return nil
                }
                let choice = choices.removeFirst()
                guard case let .choice(bits, _) = choice else {
                    return nil
                }
                
                let nextGen = try continuation(bits.convertible)
                return try self.replayWithChoicesHelper(nextGen, choices: &choices)

            case let .pick(pickChoices):
                // Consume the next choice which should be a branch
                guard !choices.isEmpty else {
                    return nil
                }
                let choice = choices.removeFirst()
                
                guard case var .group(branches) = choice else {
                    throw ReplayError.wrongInputChoice
                }
                
                // There can only be one selected pick in a group of branches
                // If one is selected, we don't have to replay the others
                if branches.contains(where: \.isSelected) {
                    branches = branches.filter(\.isSelected)
                }
                
                let nextGen = try branches
                    .firstNonNil { branch -> ReflectiveGenerator<Output>? in
                        switch branch {
                        case let .branch(_, label, choice), let .selected(.branch(_, label, choice)):
                            guard
                                // Find the sub-generator that matches the label
                                let chosenGen = pickChoices.first(where: { $0.label == label })?.generator,
                                // Process the chosen sub-generator with its children
                                let result = try replayWithChoices(chosenGen, choices: [choice])
                            else {
                                return nil
                            }
                            return try continuation(result)
                        default:
                            throw ReplayError.wrongInputChoice
                        }
                    }
                
                guard let nextGen else {
                    throw ReplayError.noSuccessfulBranch
                }

                return try self.replayWithChoicesHelper(nextGen, choices: &choices)

            case let .sequence(_, elementGenerator):
                // Consume the next choice which should be a sequence
                guard !choices.isEmpty else { 
                    return nil 
                }
                let choice = choices.removeFirst()
                
                guard case let .sequence(_, elements, _) = choice else {
                    throw ReplayError.wrongInputChoice
                }
                
                var accumulatedValues: [Any] = []
                for elementScript in elements {
                    guard let elementValue = try self.replayRecursive(elementGenerator, with: elementScript) else {
                        return nil
                    }
                    accumulatedValues.append(elementValue)
                }
                
                let nextGen = try continuation(accumulatedValues)
                return try self.replayWithChoicesHelper(nextGen, choices: &choices)

            case let .zip(generators):
                guard generators.count == choices.count else {
                    throw ReplayError.mismatchInChoicesAndGenerators
                }
                var subResults = [Any]()
                for (generator, choiceTree) in zip(generators, choices) {
                    guard let subResult = try self.replayRecursive(generator, with: choiceTree) else {
                        return nil
                    }
                    subResults.append(subResult)
                }
                let nextGen = try continuation(subResults)
                return try self.replayWithChoicesHelper(nextGen, choices: &choices)
            case let .contramap(_, subGenerator), let .prune(subGenerator):
                // A left map or prune doesn't consume choices, just passes them to the sub-generator
                guard let subResult = try self.replayWithChoicesHelper(subGenerator, choices: &choices) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try self.replayWithChoicesHelper(nextGen, choices: &choices)
            case let .just(value):
                // Consume the next choice which should be a just
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case .just = choice else {
                    return nil
                }
                
                let nextGen = try continuation(value)
                return try self.replayWithChoicesHelper(nextGen, choices: &choices)
                
            case .getSize:
                // getSize doesn't consume choices, just returns the current size
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case let .getSize(size) = choice else {
                    return nil
                }
                
                let nextGen = try continuation(size)
                return try self.replayWithChoicesHelper(nextGen, choices: &choices)
                
            case let .resize(_, subGenerator):
                // resize consumes a resize choice and replays the sub-generator
                guard !choices.isEmpty else {
                    return nil
                }
                let choice = choices.removeFirst()
                guard case let .resize(_, subChoices) = choice else {
                    return nil
                }
                
                var subChoicesCopy = subChoices
                guard let subResult = try self.replayWithChoicesHelper(subGenerator, choices: &subChoicesCopy) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try self.replayWithChoicesHelper(nextGen, choices: &choices)
            
            case let .filter(gen, _, _), let .classify(gen, _, _):
                return try self.replayWithChoicesHelper(gen, choices: &choices) as? Output
            }
        }
    }
    
    private static func replayRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with script: ChoiceTree
    ) throws -> Output? {
        
        var script = script
        if case let .important(choice) = script {
            script = choice
        }
        
        // Handle group scripts by distributing choices to the generator
        // Groups containing branches represent `picks` and are handled together
        if case let .group(choices) = script {
            if choices.allSatisfy({ $0.isBranch || $0.isSelected }) == false {
                return try replayWithChoices(gen, choices: choices)
            }
            // Handle all the pick branches together
            return try replayWithChoices(gen, choices: [script])
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
                let nextGen = try continuation(result)
                // We replay the rest of the generator with the *same* script,
                // as the operation itself doesn't consume the whole tree.
                return try self.replayRecursive(nextGen, with: script)
            }
            
            // This is the core structural match. We switch on the operation.
            switch operation {
            case .zip:
                fatalError("Unsupported")
                
            case .chooseBits:
                // This operation expects a primitive `.choice` node from the script.
                guard case let .choice(bits, _) = script else {
                    return nil
                }
                return try runContinuation(bits.convertible)

            case let .just(value):
                // This operation expects a `.just` node from the script.
                guard case .just = script else {
                    return nil
                }
                return try runContinuation(value)
                
            case .getSize:
                // This operation expects a `.getSize` node from the script.
                switch script {
                case let .choice(.unsigned(value), _):
                    return try runContinuation(value)
                case let .getSize(value):
                    return try runContinuation(value)
                default:
                    return nil
                }
                
            case let .resize(_, nextGen):
                // This operation expects a `.resize` node from the script.
                guard case let .resize(_, subChoices) = script else {
                    return nil
                }
                // For now, use the first choice tree from the array if available
                guard let firstChoice = subChoices.first else {
                    return nil
                }
                guard let subResult = try self.replayRecursive(nextGen, with: firstChoice) else {
                    return nil
                }
                return try runContinuation(subResult)

            case let .pick(choices):
                // This operation expects a `.branch` node from the script.
                guard case .branch(_, let label, let choice) = script else {
                    return nil
                }
                
                // Find the sub-generator that matches the label from the script.
                guard let chosenGen = choices.first(where: { $0.label == label })?.generator else {
                    return nil
                }
                
                // Recursively replay the chosen sub-generator with the children of this branch node.
                // A group of children is replayed as a single unit.
                guard let result = try self.replayRecursive(chosenGen, with: choice) else {
                    return nil
                }
                return result as? Output

            case let .sequence(lengthGen, elementGenerator):
                // This operation expects a `.sequence` node from the script.
                guard case let .sequence(length, elements, _) = script else {
                    return nil
                }
                
                let lengthMetadata = ChoiceMetadata(
                    validRanges: [lengthGen.associatedRange ?? length...length],
                    strategies: ShrinkingStrategy.sequenceStrategies
                )
                guard  let _ = try self.replayRecursive(lengthGen, with: .choice(.unsigned(length), lengthMetadata)) else {
                    return nil
                }
                
                var accumulatedValues: [Any] = []
                for elementScript in elements {
                    // Replay each element with its corresponding sub-tree from the script.
                    guard let elementValue = try self.replayRecursive(elementGenerator, with: elementScript) else {
                        return nil // Fail if any element fails to replay.
                    }
                    accumulatedValues.append(elementValue)
                }
                
                return try runContinuation(accumulatedValues)
                 
            // Forward-only ops don't consume choices. Their presence in a reflectable
            // generator is an error.
            case let .contramap(_, subGenerator):
                // A lens/contramap is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let subResult = try self.replayRecursive(subGenerator, with: script) else {
                    return nil
                }
                
                // Call the continuation with the subResult to handle the transformation
                let nextGen = try continuation(subResult)
                return try self.replayRecursive(nextGen, with: script)
                
            case let .prune(subGenerator):
                // A prune is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let result = try self.replayRecursive(subGenerator, with: script) else {
                    return nil
                }
                return result as? Output
            case let .filter(gen, _, _), let .classify(gen, _, _):
                guard let result = try self.replayRecursive(gen, with: script) else {
                    return nil
                }
                return result as? Output
            }
        }
    }
    
    enum ReplayError: LocalizedError {
        case wrongInputChoice
        case noSuccessfulBranch
        case mismatchInChoicesAndGenerators
    }
}
