//
//  Materialize.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

import Foundation

extension Interpreters {
    private struct Context {
        let values: ChoiceSequence
        let strictness: Strictness
        let isInstrumented: Bool

        private(set) var index: Int = 0 {
            willSet {
                if isInstrumented {
                    ExhaustLog.debug(
                        category: .materialize,
                        event: "context_advance",
                        metadata: [
                            "from": values[index...].map(\.shortString).joined(),
                            "to": values[newValue...].map(\.shortString).joined(),
                        ],
                    )
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

        init(values: ChoiceSequence, strictness: Strictness, isInstrumented: Bool) {
            self.values = values
            self.strictness = strictness
            self.isInstrumented = isInstrumented
        }

        // MARK: - Consume methods

        @discardableResult
        mutating func consumeGroup(_ isOpen: Bool, line: Int = #line) throws -> ChoiceSequenceValue {
            guard case .group(isOpen) = peek else {
                switch strictness {
                case .normal:
                    if isInstrumented {
                        ExhaustLog.debug(
                            category: .materialize,
                            event: "consume_group_failed",
                            metadata: [
                                "is_open": "\(isOpen)",
                                "line": "\(line)",
                                "remaining": shortString,
                            ],
                        )
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
                    if isInstrumented {
                        ExhaustLog.debug(
                            category: .materialize,
                            event: "consume_sequence_failed",
                            metadata: [
                                "is_open": "\(isOpen)",
                                "line": "\(line)",
                                "remaining": shortString,
                            ],
                        )
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
                if isInstrumented {
                    ExhaustLog.debug(
                        category: .materialize,
                        event: "consume_value_failed",
                        metadata: [
                            "line": "\(line)",
                            "remaining": shortString,
                        ],
                    )
                }
                throw MaterializeError.wrongInputChoice
            }
            return value
        }

        mutating func consumeValueIfPresent(line: Int = #line) -> ChoiceSequenceValue.Value? {
            guard let entry = peek else {
                if isInstrumented {
                    ExhaustLog.debug(
                        category: .materialize,
                        event: "consume_value_if_present_nil",
                        metadata: [
                            "line": "\(line)",
                            "peek": peek?.shortString ?? "nil",
                            "remaining": shortString,
                        ],
                    )
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
                if isInstrumented {
                    ExhaustLog.debug(
                        category: .materialize,
                        event: "consume_branch_if_present_nil",
                        metadata: [
                            "line": "\(line)",
                            "peek": peek?.shortString ?? "nil",
                            "remaining": shortString,
                        ],
                    )
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
        /// For reduction passes that have not changed the ChoiceTree structure
        case normal
        /// For reduction passes that have changed the structure
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
        strictness: Strictness = .normal,
    ) throws -> Output? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .materialize)
        if isInstrumented {
            ExhaustLog.debug(
                category: .materialize,
                event: "materialize_start",
                metadata: [
                    "sequence": values.shortString,
                ],
            )
        }
        // Start the recursive process. The helper returns the value and any *unconsumed*
        // parts of the tree. A successful top-level replay should consume the entire tree.
        var context = Context(values: values, strictness: strictness, isInstrumented: isInstrumented)
        let result = try materializeRecursive(gen, with: tree, context: &context)

        // We can add a check here to ensure no parts of the tree were left over,
        // but the recursive logic should handle this correctly.
        if isInstrumented, context.isAtEnd == false {
            ExhaustLog.warning(
                category: .materialize,
                event: "materialize_unconsumed_sequence",
            )
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
            return try materializeRecursiveOperation(
                operation,
                continuation: continuation,
                tree: tree,
                context: &context,
            )
        }
    }

    private static func materializeRecursiveOperation<Output>(
        _ operation: ReflectiveOperation,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        switch operation {
        case .zip, .pick:
            nil
        case .chooseBits:
            try materializeRecursiveChooseBits(continuation: continuation, tree: tree, context: &context)
        case let .just(value):
            try materializeRecursiveJust(value: value, continuation: continuation, tree: tree, context: &context)
        case .getSize:
            try materializeRecursiveGetSize(continuation: continuation, tree: tree, context: &context)
        case let .resize(_, resizedGen):
            try materializeRecursiveResize(
                resizedGen: resizedGen,
                continuation: continuation,
                tree: tree,
                context: &context,
            )
        case let .sequence(_, elementGenerator):
            try materializeRecursiveSequence(
                elementGenerator: elementGenerator,
                continuation: continuation,
                tree: tree,
                context: &context,
            )
        case let .contramap(_, subGenerator):
            try materializeRecursiveWrapped(
                subGenerator: subGenerator,
                continuation: continuation,
                tree: tree,
                context: &context,
            )
        case .prune:
            fatalError("Should not be encountered")
        case let .filter(gen, _, predicate):
            try materializeRecursiveFilter(
                gen: gen,
                predicate: predicate,
                tree: tree,
                context: &context,
            )
        case let .classify(gen, _, _):
            try materializeRecursiveClassify(gen: gen, tree: tree, context: &context)
        }
    }

    @inline(__always)
    private static func materializeRecursiveChooseBits<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        guard let value = context.consumeValueIfPresent() else {
            return nil
        }
        let nextGen = try continuation(value.choice.convertible)
        return try materializeRecursive(nextGen, with: tree, context: &context)
    }

    @inline(__always)
    private static func materializeRecursiveJust<Output>(
        value: Any,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        guard case .just = tree else {
            return nil
        }
        let nextGen = try continuation(value)
        return try materializeRecursive(nextGen, with: tree, context: &context)
    }

    @inline(__always)
    private static func materializeRecursiveGetSize<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
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
    }

    private static func materializeRecursiveResize<Output>(
        resizedGen: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        guard case let .resize(_, subChoices) = tree, let firstChoice = subChoices.first else {
            return nil
        }

        try context.consumeGroup(true)
        guard let subResult = try materializeRecursive(resizedGen, with: firstChoice, context: &context) else {
            return nil
        }
        try context.consumeGroup(false)

        let nextGen = try continuation(subResult)
        return try materializeRecursive(nextGen, with: tree, context: &context)
    }

    private static func materializeRecursiveSequence<Output>(
        elementGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
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
    }

    @inline(__always)
    private static func materializeRecursiveWrapped<Output>(
        subGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try materializeRecursive(subGenerator, with: tree, context: &context) },
            runContinuation: { subResult in
                let nextGen = try continuation(subResult)
                return try materializeRecursive(nextGen, with: tree, context: &context)
            },
        )
    }

    @inline(__always)
    private static func materializeRecursiveFilter<Output>(
        gen: ReflectiveGenerator<Any>,
        predicate: (Any) -> Bool,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        guard let subResult = try materializeRecursive(gen, with: tree, context: &context),
              let result = subResult as? Output,
              predicate(result)
        else {
            return nil
        }
        return result
    }

    @inline(__always)
    private static func materializeRecursiveClassify<Output>(
        gen: ReflectiveGenerator<Any>,
        tree: ChoiceTree,
        context: inout Context,
    ) throws -> Output? {
        guard let subResult = try materializeRecursive(gen, with: tree, context: &context),
              let result = subResult as? Output
        else {
            return nil
        }
        return result
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
            value

        case let .impure(operation, continuation):
            try materializeWithChoicesOperation(
                operation,
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        }
    }

    private static func materializeWithChoicesOperation<Output>(
        _ operation: ReflectiveOperation,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        switch operation {
        case .chooseBits:
            try materializeWithChoicesChooseBits(
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case let .pick(pickChoices):
            try materializeWithChoicesPick(
                pickChoices: pickChoices,
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case let .sequence(_, elementGenerator):
            try materializeWithChoicesSequence(
                elementGenerator: elementGenerator,
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case let .zip(generators):
            try materializeWithChoicesZip(
                generators: generators,
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case let .contramap(_, subGenerator), let .prune(subGenerator):
            try materializeWithChoicesWrapped(
                subGenerator: subGenerator,
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case let .just(value):
            try materializeWithChoicesJust(
                value: value,
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case .getSize:
            try materializeWithChoicesGetSize(
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case let .resize(_, subGenerator):
            try materializeWithChoicesResize(
                subGenerator: subGenerator,
                continuation: continuation,
                choices: &choices,
                context: &context,
            )
        case let .filter(gen, _, predicate):
            try materializeWithChoicesFilter(
                gen: gen,
                predicate: predicate,
                choices: &choices,
                context: &context,
            )
        case let .classify(gen, _, _):
            try materializeWithChoicesClassify(
                gen: gen,
                choices: &choices,
                context: &context,
            )
        }
    }

    @inline(__always)
    private static func materializeWithChoicesChooseBits<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard choices.isEmpty == false else {
            return nil
        }
        _ = choices.removeFirst()
        guard let value = context.consumeValueIfPresent() else {
            return nil
        }

        let nextGen = try continuation(value.choice.convertible)
        return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
    }

    private static func materializeWithChoicesPick<Output>(
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard choices.isEmpty == false, let choice = choices.removeFirst() else {
            return nil
        }
        guard case let .group(branches) = choice else {
            if context.strictness == .relaxed {
                return nil
            }
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
        } else if branchMarker == nil, let selectedBranch = PickBranchResolution.firstSelectedBranch(in: branches) {
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
            if context.strictness == .relaxed {
                return nil
            }
            throw MaterializeError.noSuccessfulBranch
        }

        try context.consumeGroup(false)
        return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
    }

    private static func materializeWithChoicesSequence<Output>(
        elementGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard choices.isEmpty == false, let choice = choices.removeFirst() else {
            return nil
        }
        guard case let .sequence(_, elements, lengthMeta) = choice else {
            if context.strictness == .relaxed {
                return nil
            }
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
    }

    private static func materializeWithChoicesZip<Output>(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard generators.isEmpty == false else {
            let nextGen = try continuation([])
            return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
        }

        typealias ZipAttempt = (scripts: [ChoiceTree], consumedChoices: Int, consumesContextGroup: Bool)
        var attempts: [ZipAttempt] = []

        if let firstChoice = choices.element(atOffset: 0),
           case let .group(children) = firstChoice,
           children.allSatisfy({ $0.isBranch || $0.isSelected }) == false
        {
            attempts.append((scripts: children, consumedChoices: 1, consumesContextGroup: true))
        }

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
    }

    @inline(__always)
    private static func materializeWithChoicesWrapped<Output>(
        subGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try materializeWithChoicesHelper(subGenerator, with: &choices, context: &context) },
            runContinuation: { subResult in
                let nextGen = try continuation(subResult)
                return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
            },
        )
    }

    @inline(__always)
    private static func materializeWithChoicesJust<Output>(
        value: Any,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard choices.isEmpty == false,
              let choice = choices.removeFirst(),
              case .just = choice
        else {
            return nil
        }

        let nextGen = try continuation(value)
        return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
    }

    @inline(__always)
    private static func materializeWithChoicesGetSize<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard choices.isEmpty == false,
              let choice = choices.removeFirst(),
              case let .getSize(size) = choice
        else {
            return nil
        }

        let nextGen = try continuation(size)
        return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
    }

    @inline(__always)
    private static func materializeWithChoicesResize<Output>(
        subGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard choices.isEmpty == false,
              let choice = choices.removeFirst(),
              case let .resize(_, subChoices) = choice
        else {
            return nil
        }

        var subChoicesCursor = ChoiceCursor(choices: subChoices)
        guard let subResult = try materializeWithChoicesHelper(subGenerator, with: &subChoicesCursor, context: &context) else {
            return nil
        }
        let nextGen = try continuation(subResult)
        return try materializeWithChoicesHelper(nextGen, with: &choices, context: &context)
    }

    @inline(__always)
    private static func materializeWithChoicesFilter<Output>(
        gen: ReflectiveGenerator<Any>,
        predicate: (Any) -> Bool,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard let subResult = try materializeWithChoicesHelper(gen, with: &choices, context: &context),
              let result = subResult as? Output,
              predicate(result)
        else {
            return nil
        }
        return result
    }

    @inline(__always)
    private static func materializeWithChoicesClassify<Output>(
        gen: ReflectiveGenerator<Any>,
        choices: inout ChoiceCursor,
        context: inout Context,
    ) throws -> Output? {
        guard let subResult = try materializeWithChoicesHelper(gen, with: &choices, context: &context),
              let result = subResult as? Output
        else {
            return nil
        }
        return result
    }

    private static func materializePickBranch<Output>(
        _ branch: ChoiceTree,
        generators: [ReflectiveGenerator<Any>],
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        context: inout Context,
    ) throws -> ReflectiveGenerator<Output>? {
        guard let unpacked = PickBranchResolution.unpack(branch) else {
            throw MaterializeError.wrongInputChoice
        }

        // Fast path: exact ID match
        let index = Int(exactly: unpacked.id)!
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
            if context.isInstrumented {
                ExhaustLog.debug(
                    category: .materialize,
                    event: "pick_branch_fast_path",
                    metadata: [
                        "branch_id": "\(unpacked.id)",
                    ],
                )
            }
            return result
        }

        guard context.strictness == .relaxed else {
            return nil
        }

        // Fallback: branch ID not recognized (structurally edited tree).
        // Try each generator against the branch's choice content.
        if context.isInstrumented {
            ExhaustLog.debug(
                category: .materialize,
                event: "pick_branch_fallback_start",
                metadata: [
                    "excluded_branch_id": "\(unpacked.id)",
                ],
            )
        }
        var generators = generators
        generators.remove(at: index)
        for generator in generators {
            var attemptContext = context
            if let result = try? materializeRecursive(generator, with: unpacked.choice, context: &attemptContext) {
                if context.isInstrumented {
                    ExhaustLog.debug(
                        category: .materialize,
                        event: "pick_branch_fallback_succeeded",
                        metadata: [
                            "branch_id": "\(unpacked.id)",
                        ],
                    )
                }
                context = attemptContext
                // We're in a mismatched group. Consume as much leftover data as you can
                context.skipToMatchingGroupClose()
                return try continuation(result)
            }
        }
        // We're in a mismatched group. Consume as much leftover data as you can
        if context.isInstrumented {
            ExhaustLog.debug(
                category: .materialize,
                event: "pick_branch_fallback_failed",
                metadata: [
                    "branch_id": "\(unpacked.id)",
                ],
            )
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
