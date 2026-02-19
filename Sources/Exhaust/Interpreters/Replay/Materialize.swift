//
//  Materialize.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

import Foundation

extension Interpreters {
    private struct Context {
        static let isInstrumented = false
        let values: ChoiceSequence
        let strictness: Strictness

        private(set) var index: Int = 0 {
            willSet {
                if Context.isInstrumented {
                    print("Context being consumed: \(values[index...].map(\.shortString).joined()) -> \(values[newValue...].map(\.shortString).joined())")
                }
            }
        }

        var peek: ChoiceSequenceValue? {
            guard index < values.count else {
                return nil
            }
            return values[index]
        }
        
        
        var shortString: String {
            values[index...].map(\.shortString).joined()
        }

        var isAtEnd: Bool {
            index >= values.count
        }

        init(values: ChoiceSequence, strictness: Strictness) {
            self.values = values
            self.strictness = strictness
        }

        // MARK: - Consume methods

        @discardableResult
        mutating func consumeGroup(_ isOpen: Bool, line: Int = #line) throws -> ChoiceSequenceValue {
            guard case .group(isOpen) = peek else {
                switch strictness {
                case .normal:
                    if Self.isInstrumented {
                        print("Throwing group consume error \(isOpen) from line \(line) - \(shortString)")
                    }
                    throw isOpen ? MaterializeError.groupNotOpen : .groupNotClosed
                case .relaxed:
                    return .group(isOpen)
                }
            }
            defer { index += 1 }
            return .group(isOpen)
        }

        @discardableResult
        mutating func consumeSequence(_ isOpen: Bool, line: Int = #line) throws -> ChoiceSequenceValue {
            guard case .sequence(isOpen) = peek else {
                switch strictness {
                case .normal:
                    if Self.isInstrumented {
                        print("Throwing sequence consume error \(isOpen) from line \(line) - \(shortString)")
                    }
                    throw isOpen ? MaterializeError.sequenceNotOpen : .sequenceNotClosed
                case .relaxed:
                    return .sequence(isOpen)
                }
            }
            defer { index += 1 }
            return .sequence(isOpen)
        }

        mutating func consumeValue(line: Int = #line) throws -> ChoiceSequenceValue.Value {
            guard let value = consumeValueIfPresent() else {
                if Self.isInstrumented {
                    print("Throwing value consume error from line \(line) - \(shortString)")
                }
                throw MaterializeError.wrongInputChoice
            }
            return value
        }

        mutating func consumeValueIfPresent(line: Int = #line) -> ChoiceSequenceValue.Value? {
            guard let entry = peek else {
                if Self.isInstrumented {
                    print("consumeValueIfPresent returning nil from line \(line), got \(peek?.shortString ?? "nil") - \(shortString)")
                }
                return nil
            }
            switch entry {
            case let .value(v), let .reduced(v):
                index += 1
                return v
            default:
                return nil
            }
        }

        mutating func consumeBranchIfPresent(line: Int = #line) -> ChoiceSequenceValue.Branch? {
            guard case let .branch(v) = peek else {
                if Self.isInstrumented {
                    print("consumeBranchIfPresent returning nil from line \(line), got \(peek?.shortString ?? "nil") - \(shortString)")
                }
                return nil
            }
            index += 1
            return v
        }
        
        mutating func skipToMatchingGroupClose() {
            var depth = 0
            while !isAtEnd {
                switch peek {
                case .group(true):
                    depth += 1
                    index += 1
                case .group(false):
                    if depth == 0 {
                        return
                    }
                    depth -= 1
                    index += 1
                default:
                    index += 1
                }
            }
        }
    }

    private struct ChoiceCursor {
        // swiftlint:disable:next nesting
        private enum Storage {
            case one(ChoiceTree)
            case many([ChoiceTree])
        }

        private let storage: Storage
        private(set) var index: Int = 0

        init(choice: ChoiceTree) {
            storage = .one(choice)
        }

        init(choices: [ChoiceTree]) {
            storage = .many(choices)
        }

        var isEmpty: Bool {
            index >= count
        }

        var remainingCount: Int {
            count - index
        }

        mutating func removeFirst() -> ChoiceTree? {
            guard let value = element(at: index) else {
                return nil
            }
            index += 1
            return value
        }

        func element(atOffset offset: Int) -> ChoiceTree? {
            element(at: index + offset)
        }

        private var count: Int {
            switch storage {
            case .one:
                1
            case let .many(choices):
                choices.count
            }
        }

        private func element(at absoluteIndex: Int) -> ChoiceTree? {
            guard absoluteIndex >= 0, absoluteIndex < count else {
                return nil
            }
            switch storage {
            case let .one(choice):
                return choice
            case let .many(choices):
                return choices[absoluteIndex]
            }
        }
    }
    
    public enum Strictness: Equatable {
        // For reduction passes that have not changed the ChoiceTree structure
        case normal
        // For reduction passes that have changed the structure
        case relaxed
    }

    // ... `generate` and `reflect` and their helpers ...

    // MARK: - Public-Facing Materialize Function

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
        using values: ChoiceSequence,
        strictness: Strictness = .normal
    ) throws -> Output? {
        if Context.isInstrumented {
            print("Starting materialize for \(values.shortString)")
        }
        // Start the recursive process. The helper returns the value and any *unconsumed*
        // parts of the tree. A successful top-level replay should consume the entire tree.
        var context = Context(values: values, strictness: strictness)
        let result = try materializeRecursive(gen, with: tree, context: &context)

        // We can add a check here to ensure no parts of the tree were left over,
        // but the recursive logic should handle this correctly.
        if Context.isInstrumented, context.isAtEnd == false {
            print("Unexpected result: the `ChoiceSequence` should have been fully consumed")
        }
        return result
    }

    private static func materializeRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        // Handle group scripts by distributing choices to the generator
        // Groups containing branches represent `picks` and are handled together
        if case let .group(choices) = tree {
            var result: Output?

            if choices.allSatisfy({ $0.isBranch || $0.isSelected }) == false {
                try context.consumeGroup(true)
                result = try materializeWithChoices(gen, with: choices, context: &context)
                // If we have consumed fewer values than expected, this will fail
                try context.consumeGroup(false)
            } else {
                // Handle all the pick branches together
                result = try materializeWithChoice(gen, with: tree, context: &context)
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
                // Zips are normally wrapped in groups and handled by materializeWithChoicesHelper.
                // Return nil so that fallback probing in materializePickBranch can recover.
                return nil

            case .chooseBits:
                // This operation expects a primitive `.choice` node from the script.
                // We are failing here
                guard let value = context.consumeValueIfPresent() else {
                    return nil
                }
                let nextGen = try continuation(value.choice.convertible)
                return try materializeRecursive(nextGen, with: tree, context: &context)

            case let .just(value):
                // This operation expects a `.just` node from the script.
                guard case .just = tree else {
                    return nil
                }
                let nextGen = try continuation(value)
                return try materializeRecursive(nextGen, with: tree, context: &context)

            case .getSize:
                // This operation expects a `.getSize` node from the script.
                switch tree {
                case let .choice(.unsigned(value, _), _):
                    let nextGen = try continuation(value)
                    return try materializeRecursive(nextGen, with: tree, context: &context)
                case let .getSize(value):
                    let nextGen = try continuation(value)
                    return try materializeRecursive(nextGen, with: tree, context: &context)
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

                guard let subResult = try materializeRecursive(resizedGen, with: firstChoice, context: &context) else {
                    return nil
                }

                try context.consumeGroup(false)

                let nextGen = try continuation(subResult)
                return try materializeRecursive(nextGen, with: tree, context: &context)

            case .pick:
                // Picks are normally wrapped in groups and handled by materializeWithChoicesHelper.
                // Return nil so that fallback probing in materializePickBranch can recover.
                return nil
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
                    context: &context,
                    requireElements: false,
                    validLengthRanges: lengthMeta.validRanges,
                ) else {
                    return nil
                }

                let nextGen = try continuation(result)
                return try materializeRecursive(nextGen, with: tree, context: &context)

            // Forward-only ops don't consume choices. Their presence in a reflectable
            // generator is an error.
            case let .contramap(_, subGenerator):
//                fatalError("Should not be encountered")
                // A lens/contramap is a wrapper. It doesn't consume a node from the script itself.
                // The choices are consumed by its sub-generator. We pass the same script down.
                guard let subResult = try materializeRecursive(subGenerator, with: tree, context: &context) else {
                    return nil
                }

                let nextGen = try continuation(subResult)
                return try materializeRecursive(nextGen, with: tree, context: &context)

            case .prune:
                fatalError("Should not be encountered")

//                guard let result = try self.materializeRecursive(subGenerator, with: tree, context: &context) else {
//                    return nil
//                }
//                return result as? Output
            case let .filter(gen, _, predicate):
                let result = try materializeRecursive(gen, with: tree, context: &context) as? Output
                guard let result,
                      predicate(result)
                else {
                    return nil
                }
                return result

            case let .classify(gen, _, _):
                guard let result = try materializeRecursive(gen, with: tree, context: &context)
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
        context: inout Context,
        requireElements: Bool,
        validLengthRanges: [ClosedRange<UInt64>] = [],
    ) throws -> [Any]? {
        try context.consumeSequence(true)

        var accumulatedValues: [Any] = []
        if validLengthRanges.count == 1,
           let firstRange = validLengthRanges.first,
           firstRange.lowerBound == firstRange.upperBound,
           firstRange.lowerBound <= UInt64(Int.max)
        {
            accumulatedValues.reserveCapacity(Int(firstRange.lowerBound))
        }

        if let elementScript {
            while context.peek != .sequence(false), !context.isAtEnd {
                let elementValue = try materializeRecursive(elementGenerator, with: elementScript, context: &context)
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
        context: inout Context,
    ) throws -> Output? {
        var cursor = ChoiceCursor(choices: choices)
        return try materializeWithChoicesHelper(gen, with: &cursor, context: &context)
    }

    private static func materializeWithChoice<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with choice: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        var cursor = ChoiceCursor(choice: choice)
        return try materializeWithChoicesHelper(gen, with: &cursor, context: &context)
    }

    private static func materializeWithChoicesHelper<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with choices: inout ChoiceCursor,
        context: inout Context,
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
                guard let value = context.consumeValueIfPresent() else {
                    return nil
                }

                let nextGen = try continuation(value.choice.convertible)
                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)

            case let .pick(pickChoices):
                // Consume the next choice which should be a branch
                guard !choices.isEmpty else {
                    return nil
                }
                guard let choice = choices.removeFirst() else {
                    return nil
                }

                guard case let .group(branches) = choice else {
                    if context.strictness == .relaxed { return nil }
                    throw MaterializeError.wrongInputChoice
                }

                try context.consumeGroup(true)

                let generators = pickChoices.map(\.generator)
                let branchMarker = context.consumeBranchIfPresent()
                var nextGen: ReflectiveGenerator<Output>?

                if let branchMarker, let branch = branches.first(where: { $0.branchId == branchMarker.id }) {
                    nextGen = try materializePickBranch(
                        branch,
                        generators: generators,
                        continuation: continuation,
                        context: &context,
                    )
                } else if branchMarker == nil, let selectedBranch = firstSelectedBranch(in: branches) {
                    nextGen = try materializePickBranch(
                        selectedBranch,
                        generators: generators,
                        continuation: continuation,
                        context: &context,
                    )
                } else {
                    for branch in branches {
                        nextGen = try materializePickBranch(
                            branch,
                            generators: generators,
                            continuation: continuation,
                            context: &context,
                        )
                        if nextGen != nil {
                            break
                        }
                    }
                }

                guard let nextGen else {
                    if context.strictness == .relaxed { return nil }
                    throw MaterializeError.noSuccessfulBranch
                }

                try context.consumeGroup(false)

                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)

            case let .sequence(_, elementGenerator):
                // Consume the next choice which should be a sequence
                guard !choices.isEmpty else {
                    return nil
                }
                guard let choice = choices.removeFirst() else {
                    return nil
                }

                guard case let .sequence(_, elements, lengthMeta) = choice else {
                    if context.strictness == .relaxed { return nil }
                    throw MaterializeError.wrongInputChoice
                }

                guard let result = try materializeSequenceElements(
                    using: elementGenerator,
                    elementScript: elements.first,
                    context: &context,
                    requireElements: true,
                    validLengthRanges: lengthMeta.validRanges,
                ) else {
                    return nil
                }

                let nextGen = try continuation(result)
                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)

            case let .zip(generators):
                guard generators.isEmpty == false else {
                    let nextGen = try continuation([])
                    return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
                }

                typealias ZipAttempt = (scripts: [ChoiceTree], consumedChoices: Int, consumesContextGroup: Bool)
                var attempts: [ZipAttempt] = []

                // Representation A (nested): one choice containing a group of zip children.
                if let firstChoice = choices.element(atOffset: 0),
                   case let .group(children) = firstChoice,
                   children.allSatisfy({ $0.isBranch || $0.isSelected }) == false
                {
                    attempts.append((scripts: children, consumedChoices: 1, consumesContextGroup: true))
                }

                // Representation B (flat): zip children are sibling choices in the current frame.
                if choices.remainingCount >= generators.count {
                    let flatChildren = (0 ..< generators.count).compactMap { choices.element(atOffset: $0) }
                    attempts.append((scripts: flatChildren, consumedChoices: generators.count, consumesContextGroup: false))
                }

                for attempt in attempts where attempt.scripts.count == generators.count {
                    var attemptContext = context
                    if attempt.consumesContextGroup {
                        do {
                            try attemptContext.consumeGroup(true)
                        } catch {
                            continue
                        }
                    }
                    var subResults = [Any]()
                    subResults.reserveCapacity(generators.count)
                    var didSucceed = true

                    for (generator, script) in zip(generators, attempt.scripts) {
                        guard let subResult = try materializeRecursive(generator, with: script, context: &attemptContext) else {
                            didSucceed = false
                            break
                        }
                        subResults.append(subResult)
                    }

                    guard didSucceed else {
                        continue
                    }

                    if attempt.consumesContextGroup {
                        do {
                            try attemptContext.consumeGroup(false)
                        } catch {
                            continue
                        }
                    }

                    context = attemptContext
                    for _ in 0 ..< attempt.consumedChoices {
                        _ = choices.removeFirst()
                    }

                    let nextGen = try continuation(subResults)
                    return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
                }

                return nil

            case let .contramap(_, subGenerator), let .prune(subGenerator):
                // A left map or prune doesn't consume choices, just passes them to the sub-generator
                guard let subResult = try materializeWithChoicesHelper(subGenerator, with: &choices, context: &context) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)

            case let .just(value):
                // Consume the next choice which should be a just
                guard !choices.isEmpty else { return nil }
                guard let choice = choices.removeFirst() else {
                    return nil
                }
                guard case .just = choice else {
                    return nil
                }

                let nextGen = try continuation(value)
                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)

            case .getSize:
                // getSize doesn't consume choices, just returns the current size
                guard !choices.isEmpty else { return nil }
                guard let choice = choices.removeFirst() else {
                    return nil
                }
                guard case let .getSize(size) = choice else {
                    return nil
                }

                let nextGen = try continuation(size)
                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)

            case let .resize(_, subGenerator):
                // resize consumes a resize choice and replays the sub-generator
                guard !choices.isEmpty else {
                    return nil
                }
                guard let choice = choices.removeFirst() else {
                    return nil
                }
                guard case let .resize(_, subChoices) = choice else {
                    return nil
                }

                var subChoicesCursor = ChoiceCursor(choices: subChoices)
                guard let subResult = try materializeWithChoicesHelper(subGenerator, with: &subChoicesCursor, context: &context) else {
                    return nil
                }
                let nextGen = try continuation(subResult)
                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)

            case let .filter(gen, _, predicate):
                let result = try materializeWithChoicesHelper(gen, with: &choices, context: &context) as? Output
                guard let result,
                      predicate(result)
                else {
                    return nil
                }
                return result

            case let .classify(gen, _, _):
                return try materializeWithChoicesHelper(gen, with: &choices, context: &context) as? Output
            }
        }
    }

    private static func pickChoicesByLabel(_ choices: ContiguousArray<ReflectiveOperation.PickTuple>) -> [UInt64: ReflectiveGenerator<Any>] {
        var byLabel: [UInt64: ReflectiveGenerator<Any>] = [:]
        byLabel.reserveCapacity(choices.count)
        for choice in choices where byLabel[choice.id] == nil {
            byLabel[choice.id] = choice.generator
        }
        return byLabel
    }

    private static func firstSelectedBranch(in branches: [ChoiceTree]) -> ChoiceTree? {
        for branch in branches where branch.isSelected {
            return branch
        }
        return nil
    }

    private static func unpackPickBranch(_ branch: ChoiceTree) throws -> (label: UInt64, choice: ChoiceTree) {
        switch branch {
        case let .branch(_, id, _, choice), let .selected(.branch(_, id, _, choice)):
            return (label: id, choice: choice)
        default:
            throw MaterializeError.wrongInputChoice
        }
    }

    private static func materializePickBranch<Output>(
        _ branch: ChoiceTree,
        generators: [ReflectiveGenerator<Any>],
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        context: inout Context,
    ) throws -> ReflectiveGenerator<Output>? {
        let unpacked = try unpackPickBranch(branch)

        // Fast path: exact ID match
        let index = Int(exactly: branch.unwrapped.branchId!)!
        let chosenGen = generators[index]
        var attemptContext = context
        let result = switch context.strictness {
        case .normal:
                try materializeRecursive(chosenGen, with: unpacked.choice, context: &attemptContext)
        case .relaxed:
            try? materializeRecursive(chosenGen, with: unpacked.choice, context: &attemptContext)
        }
        if let result {
            context = attemptContext
            let result = try continuation(result)
            if Context.isInstrumented {
                print("Successful fast path: \(result)")
            }
            return result
        }
        
        guard context.strictness == .relaxed else {
            return nil
        }

        // Fallback: branch ID not recognized (structurally edited tree).
        // Try each generator against the branch's choice content.
        if Context.isInstrumented {
            print("FB attempting all generators except the matching")
        }
        var generators = generators
        generators.remove(at: index)
        for generator in generators {
            var attemptContext = context
            if let result = try? materializeRecursive(generator, with: unpacked.choice, context: &attemptContext) {
                if Context.isInstrumented {
                    print("Successful FB: \(result)")
                }
                context = attemptContext
                // We're in a mismatched group. Consume as much leftover data as you can
                context.skipToMatchingGroupClose()
                return try continuation(result)
            }
        }
        // We're in a mismatched group. Consume as much leftover data as you can
        if Context.isInstrumented {
            print("FB unsuccessful, skipping to group close")
        }
        context.skipToMatchingGroupClose()
        return nil
    }

    enum MaterializeError: LocalizedError {
        case wrongInputChoice
        case noSuccessfulBranch
        case mismatchInChoicesAndGenerators
        case groupNotOpen
        case groupNotClosed
        case sequenceNotOpen
        case sequenceNotClosed
    }
}
