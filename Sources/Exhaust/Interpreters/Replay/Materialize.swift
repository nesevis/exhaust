//
//  ReplaySequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

import Foundation

extension Interpreters {
    private final class Context {
        let originalValues: ChoiceSequence
        var values: ChoiceSequence.SubSequence

        var peek: ChoiceSequenceValue? {
            values.first
        }

        init(values: ChoiceSequence) {
            self.originalValues = values
            self.values = values[...]
        }

        // MARK: - Consume methods

        @discardableResult
        func consumeGroup(_ isOpen: Bool) throws -> ChoiceSequenceValue {
            guard case .group(isOpen) = values.first else {
                throw isOpen ? ReplaySequenceError.groupNotOpen : .groupNotClosed
            }
            return values.removeFirst()
        }

        @discardableResult
        func consumeSequence(_ isOpen: Bool) throws -> ChoiceSequenceValue {
            guard case .sequence(isOpen) = values.first else {
                throw isOpen ? ReplaySequenceError.sequenceNotOpen : .sequenceNotClosed
            }
            return values.removeFirst()
        }

        func consumeValue() throws -> ChoiceSequenceValue.Value {
            switch values.first {
            case let .value(v), let .reduced(v):
                values.removeFirst()
                return v
            default:
                throw ReplaySequenceError.wrongInputChoice
            }
        }

        func consumeBranch() throws -> ChoiceSequenceValue.Value {
            guard case let .branch(v) = values.first else {
                throw ReplaySequenceError.wrongInputChoice
            }
            values.removeFirst()
            return v
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
        using values: ChoiceSequence
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
                try context.consumeGroup(true)
                result = try materializeWithChoices(gen, with: choices, context: context)
                try context.consumeGroup(false)
            } else {
                // Handle all the pick branches together
                result = try materializeWithChoices(gen, with: [tree], context: context)
            }

            return result
        }

        switch gen {
        case let .pure(value):
            // Base case: The generator is done. Return the final value.
            return value

        case let .impure(operation, continuation):
            // This is the core structural match. We switch on the operation.
            switch operation {
            case .zip:
                fatalError("When being materialized this should be a group")

            case .chooseBits:
                // This operation expects a primitive `.choice` node from the script.
                guard let value = try? context.consumeValue() else {
                    return nil
                }
                let nextGen = try continuation(value.choice.convertible)
                return try materializeRecursive(nextGen, with: tree, context: context)

            case let .just(value):
                // This operation expects a `.just` node from the script.
                guard case .just = tree else {
                    return nil
                }
                let nextGen = try continuation(value)
                return try materializeRecursive(nextGen, with: tree, context: context)

            case .getSize:
                // This operation expects a `.getSize` node from the script.
                switch tree {
                case let .choice(.unsigned(value), _):
                    let nextGen = try continuation(value)
                    return try materializeRecursive(nextGen, with: tree, context: context)
                case let .getSize(value):
                    let nextGen = try continuation(value)
                    return try materializeRecursive(nextGen, with: tree, context: context)
                default:
                    return nil
                }

            case let .resize(_, resizedGen):
                // This operation expects a `.resize` node from the script.
                guard case let .resize(_, subChoices) = tree else {
                    return nil
                }
                // For now, use the first choice tree from the array if available
                // TODO: Is this correct behaviour?
                guard let firstChoice = subChoices.first else {
                    return nil
                }
                
                try context.consumeGroup(true)
                
                guard let subResult = try self.materializeRecursive(resizedGen, with: firstChoice, context: context) else {
                    return nil
                }
                
                try context.consumeGroup(false)
                
                let nextGen = try continuation(subResult)
                return try materializeRecursive(nextGen, with: tree, context: context)

            case let .pick(choices):
                fatalError("No 'naked' picks should be materialized. They will all be wrapped in a group")
//                // This operation expects a `.branch` node from the script.
//                guard case .branch(_, let label, let choice) = tree else {
//                    return nil
//                }
//
//                // Find the sub-generator that matches the label from the script.
//                guard let chosenGen = choices.first(where: { $0.label == label })?.generator else {
//                    return nil
//                }
//
//                // Recursively replay the chosen sub-generator with the children of this branch node.
//                guard let result = try self.materializeRecursive(chosenGen, with: choice, context: context) else {
//                    return nil
//                }
//                return result as? Output

            case let .sequence(_, elementGenerator):
                // This operation expects a `.sequence` node from the script.
                guard case let .sequence(_, elements, lengthMeta) = tree else {
                    return nil
                }

                guard let result = try materializeSequenceElements(
                    using: elementGenerator,
                    elementScript: elements.first,
                    context: context,
                    requireElements: false,
                    validLengthRanges: lengthMeta.validRanges
                ) else {
                    return nil
                }

                let nextGen = try continuation(result)
                return try materializeRecursive(nextGen, with: tree, context: context)

            // Forward-only ops don't consume choices. Their presence in a reflectable
            // generator is an error.
            case let .contramap(_, subGenerator):
//                fatalError("Should not be encountered")
                // A lens/contramap is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let subResult = try self.materializeRecursive(subGenerator, with: tree, context: context) else {
                    return nil
                }

                let nextGen = try continuation(subResult)
                return try self.materializeRecursive(nextGen, with: tree, context: context)

            case let .prune(subGenerator):
                fatalError("Should not be encountered")
                guard let result = try self.materializeRecursive(subGenerator, with: tree, context: context) else {
                    return nil
                }
                return result as? Output
            case let .filter(gen, _, predicate):
                let result = try self.materializeRecursive(gen, with: tree, context: context) as? Output
                guard
                    let result,
                    predicate(result)
                else {
                    return nil
                }
                return result
            case let .classify(gen, _, _):
                guard
                    let result = try self.materializeRecursive(gen, with: tree, context: context)
                else {
                    return nil
                }
                return result as? Output
            }
        }
    }

    // MARK: - Shared Helpers

    /// Materializes a sequence of elements by consuming sequence open/close markers
    /// and looping over elements until the sequence end marker is reached.
    ///
    /// When `validLengthRanges` is non-empty, the materialized element count must fall
    /// within one of the ranges — otherwise the candidate is rejected. This enforces
    /// constraints from the sequence's length generator (e.g. `exactly: 10`).
    private static func materializeSequenceElements(
        using elementGenerator: ReflectiveGenerator<Any>,
        elementScript: ChoiceTree?,
        context: Context,
        requireElements: Bool,
        validLengthRanges: [ClosedRange<UInt64>] = []
    ) throws -> [Any]? {
        try context.consumeSequence(true)

        var accumulatedValues: [Any] = []

        if let elementScript {
            while context.peek != .sequence(false) {
                let elementValue = try self.materializeRecursive(elementGenerator, with: elementScript, context: context)
                if let elementValue {
                    accumulatedValues.append(elementValue)
                } else if requireElements {
                    return nil
                }
            }
        }

        try context.consumeSequence(false)

        if validLengthRanges.isEmpty == false {
            let count = UInt64(accumulatedValues.count)
            if validLengthRanges.contains(where: { $0.contains(count) }) == false {
                return nil
            }
        }

        return accumulatedValues
    }

    // MARK: - Private Recursive Materialization Engine

    private static func materializeWithChoices<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with choices: [ChoiceTree],
        context: Context
    ) throws -> Output? {
        var remainingChoices = choices
        return try materializeWithChoicesHelper(gen, with: &remainingChoices[...], context: context)
    }

    private static func materializeWithChoicesHelper<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with choices: inout [ChoiceTree].SubSequence,
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
                guard let value = try? context.consumeValue() else {
                    return nil
                }

                let nextGen = try continuation(value.choice.convertible)
                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)

            case let .pick(pickChoices):
                // Consume the next choice which should be a branch
                guard !choices.isEmpty else {
                    return nil
                }
                let choice = choices.removeFirst()

                guard case var .group(branches) = choice else {
                    throw ReplaySequenceError.wrongInputChoice
                }

                try context.consumeGroup(true)
                
                if let sequenceBranch = try? context.consumeBranch(), let index = sequenceBranch.choice.convertible as? Int {
                    // Now we set the branch explicitly
                    branches = branches.indices.contains(index) ? [branches[index]] : branches
                } else if branches.contains(where: \.isSelected) {
                    // There can only be one selected pick in a group of branches
                    // If one is selected, we don't have to replay the others
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
                                let result = try materializeWithChoices(chosenGen, with: [choice], context: context)
                            else {
                                return nil
                            }
                            return try continuation(result)
                        default:
                            throw ReplayError.wrongInputChoice
                        }
                    }

                guard let nextGen else {
                    throw ReplaySequenceError.noSuccessfulBranch
                }

                try context.consumeGroup(false)

                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)

            case let .sequence(_, elementGenerator):
                // Consume the next choice which should be a sequence
                guard !choices.isEmpty else {
                    return nil
                }
                let choice = choices.removeFirst()

                guard case let .sequence(_, elements, lengthMeta) = choice else {
                    throw ReplayError.wrongInputChoice
                }

                guard let result = try materializeSequenceElements(
                    using: elementGenerator,
                    elementScript: elements.first,
                    context: context,
                    requireElements: true,
                    validLengthRanges: lengthMeta.validRanges
                ) else {
                    return nil
                }

                let nextGen = try continuation(result)
                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)

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
                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)
            case let .contramap(_, subGenerator), let .prune(subGenerator):
                // A left map or prune doesn't consume choices, just passes them to the sub-generator
                guard let subResult = try self.materializeWithChoicesHelper(subGenerator, with: &choices, context: context) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)
            case let .just(value):
                // Consume the next choice which should be a just
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case .just = choice else {
                    return nil
                }

                let nextGen = try continuation(value)
                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)

            case .getSize:
                // getSize doesn't consume choices, just returns the current size
                guard !choices.isEmpty else { return nil }
                let choice = choices.removeFirst()
                guard case let .getSize(size) = choice else {
                    return nil
                }

                let nextGen = try continuation(size)
                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)

            case let .resize(_, subGenerator):
                // resize consumes a resize choice and replays the sub-generator
                guard !choices.isEmpty else {
                    return nil
                }
                let choice = choices.removeFirst()
                guard case let .resize(_, subChoices) = choice else {
                    return nil
                }

                var subChoicesSlice = subChoices[...]
                guard let subResult = try self.materializeWithChoicesHelper(subGenerator, with: &subChoicesSlice, context: context) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try self.materializeWithChoicesHelper(nextGen, with: &choices, context: context)

            case let .filter(gen, _, predicate):
                let result = try self.materializeWithChoicesHelper(gen, with: &choices, context: context) as? Output
                guard
                    let result,
                    predicate(result)
                else {
                    return nil
                }
                return result
                
            case let .classify(gen, _, _):
                return try self.materializeWithChoicesHelper(gen, with: &choices, context: context) as? Output
            }
        }
    }

    enum ReplaySequenceError: LocalizedError {
        case wrongInputChoice
        case noSuccessfulBranch
        case mismatchInChoicesAndGenerators
        case groupNotOpen
        case groupNotClosed
        case sequenceNotOpen
        case sequenceNotClosed
    }
}
