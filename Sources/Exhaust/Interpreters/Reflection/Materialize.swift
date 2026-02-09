//
//  ReplaySequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

import Foundation

extension Interpreters {
    private final class Context {
        let originalValues: ChoiceSequence.Sequence
        var values: ChoiceSequence.Sequence.SubSequence
        
        var nextIsValue: Bool {
            values.first?.isValue ?? false
        }
        
        var isSequenceStart: Bool {
            if case .sequence(true) = values.first {
                return true
            }
            return false
        }
        
        var isSequenceEnd: Bool {
            if case .sequence(false) = values.first {
                return true
            }
            return false
        }
        
        var isStart: Bool {
            if case .group(true) = values.first {
                return true
            }
            return false
        }
        
        var isEnd: Bool {
            if case .group(false) = values.first {
                return true
            }
            return false
        }
        
        init(values: ChoiceSequence.Sequence) {
            self.originalValues = values
            self.values = values[...]
        }
    }
    // ... `generate` and `reflect` and their helpers ...

    /// MARK: - Public-Facing Materialize Function
    
    /// Deterministically reproduces a value by executing a generator with a structured `ChoiceSequence.Sequence`.
    ///
    /// - Parameters:
    ///   - gen: The generator to execute.
    ///   - choiceSequence: The unstructured script of values to follow.
    /// - Returns: The deterministically generated value, or `nil` if the tree does not
    ///   match the generator's structure.
    public static func materialize<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with tree: ChoiceTree,
        using values: ChoiceSequence.Sequence
    ) throws -> Output? {
        // Start the recursive process. The helper returns the value and any *unconsumed*
        // parts of the tree. A successful top-level replay should consume the entire tree.
        let context = Context(values: values)
        let result = try materializeRecursive(gen, with: tree, context: context)
        
        // We can add a check here to ensure no parts of the tree were left over,
        // but the recursive logic should handle this correctly.
        if context.values.isEmpty == false {
            print("Unexpected result: the `ChoiceSequence` should have been fully consumed")
        }
        return result
    }
    
    private static func materializeRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with tree: ChoiceTree,
        context: Context
    ) throws -> Output? {
        // Handle group scripts by distributing choices to the generator
        // Groups containing branches represent `picks` and are handled together
        if case let .group(choices) = tree {
            var result: Output?
            
            if choices.allSatisfy({ $0.isBranch || $0.isSelected }) == false {
                guard context.isStart, case .group(true) = context.values.removeFirst() else {
                    throw ReplaySequenceError.groupNotOpen
                }
                result = try replayWithChoices(gen, with: choices, context: context)
                guard context.isEnd, case .group(false) = context.values.removeFirst() else {
                    throw ReplaySequenceError.groupNotClosed
                }
            } else {
                // Handle all the pick branches together
                result = try replayWithChoices(gen, with: [tree], context: context)
            }
            
            // We are now expecting to clean up this group, but as only one branch was evaluated this won't work.
            
            return result
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
                return try self.materializeRecursive(nextGen, with: tree, context: context)
            }
            
            // This is the core structural match. We switch on the operation.
            switch operation {
            case .zip:
                // TODO: Why is this unsupported?
                fatalError("Unsupported")
                
            case .chooseBits:
                // This operation expects a primitive `.choice` node from the script.
                guard context.nextIsValue, case let .value(value) = context.values.removeFirst() else {
                    return nil
                }
                return try runContinuation(value.choice.convertible)

            case let .just(value):
                // This operation expects a `.just` node from the script.
                guard case .just = tree else {
                    return nil
                }
                return try runContinuation(value)
                
            case .getSize:
                // This operation expects a `.getSize` node from the script.
                switch tree {
                case let .choice(.unsigned(value), _):
                    return try runContinuation(value)
                case let .getSize(value):
                    return try runContinuation(value)
                default:
                    return nil
                }
                
            case let .resize(_, nextGen):
                // This operation expects a `.resize` node from the script.
                guard case let .resize(_, subChoices) = tree else {
                    return nil
                }
                // For now, use the first choice tree from the array if available
                // TODO: Is this correct behaviour?
                guard let firstChoice = subChoices.first else {
                    return nil
                }
                guard let subResult = try self.materializeRecursive(nextGen, with: firstChoice, context: context) else {
                    return nil
                }
                return try runContinuation(subResult)

            case let .pick(choices):
                // This operation expects a `.branch` node from the script.
                guard case .branch(_, let label, let choice) = tree else {
                    return nil
                }
                
                // TODO: This is a big one. With materialized picks we can branch out here?
                
                // Find the sub-generator that matches the label from the script.
                guard let chosenGen = choices.first(where: { $0.label == label })?.generator else {
                    return nil
                }
                
                // Recursively replay the chosen sub-generator with the children of this branch node.
                // A group of children is replayed as a single unit.
                guard let result = try self.materializeRecursive(chosenGen, with: choice, context: context) else {
                    return nil
                }
                return result as? Output

            case let .sequence(_, elementGenerator):
                // This operation expects a `.sequence` node from the script.
                guard case let .sequence(_, elements, _) = tree else {
                    return nil
                }
                
                guard context.isSequenceStart else {
                    return nil
                }
                _ = context.values.removeFirst()
                
                var accumulatedValues: [Any] = []
                // We don't know how many elements there can be here.
                // We want the ChoiceSequence to dictate how we do this.
                // Do we do a while loop?
                let elementScript = elements[0]
                while true {
                    // We don't really care about the `elementScript` here except as a blueprint for how to invoke the generator
                    if let elementValue = try self.materializeRecursive(elementGenerator, with: elementScript, context: context) {
                        accumulatedValues.append(elementValue)
                    }
                    if context.isSequenceEnd {
                        break
                    }
                }
                
//                for elementScript in elements {
//                    // Replay each element with its corresponding sub-tree from the script.
//                    if let elementValue = try self.materializeRecursive(elementGenerator, with: elementScript, context: context) {
//                        accumulatedValues.append(elementValue)
//                    }
//                    if context.isSequenceEnd {
//                        break
//                    }
//                }
                
                guard context.isSequenceEnd else {
                    fatalError("Expected group close")
                }
                _ = context.values.removeFirst()
                
                return try runContinuation(accumulatedValues)
                 
            // Forward-only ops don't consume choices. Their presence in a reflectable
            // generator is an error.
            case let .contramap(_, subGenerator):
                // A lens/contramap is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let subResult = try self.materializeRecursive(subGenerator, with: tree, context: context) else {
                    return nil
                }
                
                // Call the continuation with the subResult to handle the transformation
                let nextGen = try continuation(subResult)
                return try self.materializeRecursive(nextGen, with: tree, context: context)
                
            case let .prune(subGenerator):
                // A prune is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let result = try self.materializeRecursive(subGenerator, with: tree, context: context) else {
                    return nil
                }
                return result as? Output
            case let .filter(gen, _, _), let .classify(gen, _, _):
                guard let result = try self.materializeRecursive(gen, with: tree, context: context) else {
                    return nil
                }
                return result as? Output
            }
        }
    }

    // MARK: - Private Recursive Replay Engine
    
    private static func replayWithChoices<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with choices: [ChoiceTree],
        context: Context
    ) throws -> Output? {
        var remainingChoices = choices
        return try replayWithChoicesHelper(gen, with: &remainingChoices, context: context)
    }
    
    private static func replayWithChoicesHelper<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with choices: inout [ChoiceTree],
        context: Context
    ) throws -> Output? {
        switch gen {
        case let .pure(value):
            // At this stage we have run the generator with the ChoiceSequence value and can return it
            return value

        case let .impure(operation, continuation):
            // Handle each operation by consuming appropriate choices
            switch operation {
                
            case .chooseBits:
                // Consume the next choice
                guard !choices.isEmpty else {
                    return nil
                }
                _ = choices.removeFirst()
                guard context.nextIsValue, case let .value(value) = context.values.removeFirst() else {
                    return nil
                }
                
                let nextGen = try continuation(value.choice.convertible)
                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)

            case let .pick(pickChoices):
                // Consume the next choice which should be a branch
                guard !choices.isEmpty else {
                    return nil
                }
                let choice = choices.removeFirst()
                
                guard case var .group(branches) = choice else {
                    throw ReplaySequenceError.wrongInputChoice
                }
                
                guard context.isStart else {
                    throw ReplaySequenceError.groupNotOpen
                }
                _ = context.values.removeFirst()
                
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
                                let result = try replayWithChoices(chosenGen, with: [choice], context: context)
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
                
                guard context.isEnd else {
                    throw ReplaySequenceError.groupNotClosed
                }
                _ = context.values.removeFirst()

                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)

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
                    guard let elementValue = try self.materializeRecursive(elementGenerator, with: elementScript, context: context) else {
                        return nil
                    }
                    accumulatedValues.append(elementValue)
                }
                
                let nextGen = try continuation(accumulatedValues)
                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)

            case let .zip(generators):
                guard generators.count == choices.count else {
                    throw ReplayError.mismatchInChoicesAndGenerators
                }
                var subResults = [Any]()
                for (generator, choiceTree) in zip(generators, choices) {
                    guard let subResult = try self.materializeRecursive(generator, with: choiceTree, context: context) else {
                        return nil
                    }
                    subResults.append(subResult)
                }
                let nextGen = try continuation(subResults)
                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)
            case let .contramap(_, subGenerator), let .prune(subGenerator):
                // A left map or prune doesn't consume choices, just passes them to the sub-generator
                guard let subResult = try self.replayWithChoicesHelper(subGenerator, with: &choices, context: context) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)
            case let .just(value):
                // Consume the next choice which should be a just
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case .just = choice else {
                    return nil
                }
                
                let nextGen = try continuation(value)
                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)
                
            case .getSize:
                // getSize doesn't consume choices, just returns the current size
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case let .getSize(size) = choice else {
                    return nil
                }
                
                let nextGen = try continuation(size)
                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)
                
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
                guard let subResult = try self.replayWithChoicesHelper(subGenerator, with: &subChoicesCopy, context: context) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try self.replayWithChoicesHelper(nextGen, with: &choices, context: context)
            
            case let .filter(gen, _, _), let .classify(gen, _, _):
                return try self.replayWithChoicesHelper(gen, with: &choices, context: context) as? Output
            }
        }
    }
    
    enum ReplaySequenceError: LocalizedError {
        case wrongInputChoice
        case noSuccessfulBranch
        case mismatchInChoicesAndGenerators
        case groupNotOpen
        case groupNotClosed
    }
}
