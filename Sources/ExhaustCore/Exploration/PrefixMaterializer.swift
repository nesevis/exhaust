//
//  PrefixMaterializer.swift
//  Exhaust
//

// swiftlint:disable function_parameter_count

/// Interpreter that consumes from a choice sequence prefix, then falls back to PRNG generation when the prefix is exhausted or mismatched.
///
/// This enables Hypothesis-style "extend=full" probing: modify one entry in a flat sequence, replay the prefix, and let fresh random choices fill in beyond the modification point. No pre-materialized branches needed.
public enum PrefixMaterializer {
    public static func materialize<Output>(
        _ gen: ReflectiveGenerator<Output>,
        prefix: ChoiceSequence,
        seed: UInt64,
    ) -> (value: Output, sequence: ChoiceSequence, tree: ChoiceTree)? {
        var context = PrefixContext(
            cursor: PrefixCursor(from: prefix),
            prng: Xoshiro256(seed: seed),
            size: GenerationContext.scaledSize(forRun: 0),
        )
        guard let (value, tree) = try? generateRecursive(gen, with: (), context: &context) else {
            return nil
        }
        let sequence = ChoiceSequence(tree)
        return (value, sequence, tree)
    }
}

// MARK: - Internal State

private extension PrefixMaterializer {
    /// Position-based cursor that traverses the full `ChoiceSequence` including structural markers (`.group`, `.sequence`).
    ///
    /// Group markers (from `runContinuation` grouping and pick sites) are transparently skipped. Sequence markers are handled explicitly by `tryConsumeSequenceOpen()` / `skipSequenceClose()`.
    struct PrefixCursor: ~Copyable {
        private let entries: ChoiceSequence
        private(set) var position: Int = 0
        var exhausted: Bool = false

        init(from sequence: ChoiceSequence) {
            entries = sequence
        }

        /// Skip consecutive `.group(true/false)` and `.just` markers at the current position.
        /// Groups are transparent wrappers from `runContinuation` and pick sites.
        /// Just markers carry no data and are purely structural.
        private mutating func skipGroups() {
            while position < entries.count {
                switch entries[position] {
                case .group, .just:
                    position += 1
                default:
                    return
                }
            }
        }

        mutating func tryConsumeValue() -> ChoiceSequenceValue.Value? {
            guard !exhausted else { return nil }
            skipGroups()
            guard position < entries.count else {
                exhausted = true
                return nil
            }
            switch entries[position] {
            case let .value(v), let .reduced(v):
                position += 1
                return v
            default:
                exhausted = true
                return nil
            }
        }

        mutating func tryConsumeBranch() -> ChoiceSequenceValue.Branch? {
            guard !exhausted else { return nil }
            skipGroups()
            guard position < entries.count else {
                exhausted = true
                return nil
            }
            switch entries[position] {
            case let .branch(b):
                position += 1
                return b
            default:
                exhausted = true
                return nil
            }
        }

        /// Try to consume a `.sequence(true)` marker and return info about the sequence found in the prefix: element count and `isLengthExplicit`.
        ///
        /// On success, position advances past the `.sequence(true)` marker.
        /// Returns `nil` if cursor is exhausted or not at a sequence marker.
        mutating func tryConsumeSequenceOpen() -> (elementCount: Int, isLengthExplicit: Bool)? {
            guard !exhausted else { return nil }
            skipGroups()
            guard position < entries.count else {
                exhausted = true
                return nil
            }
            guard case let .sequence(true, isLengthExplicit: isExplicit) = entries[position] else {
                // Not at a sequence marker — structural mismatch
                exhausted = true
                return nil
            }
            position += 1

            guard let count = countTopLevelElements(from: position) else {
                exhausted = true
                return nil
            }
            return (elementCount: count, isLengthExplicit: isExplicit)
        }

        /// Skip past the matching `.sequence(false)` marker after all elements have been consumed.
        mutating func skipSequenceClose() {
            guard !exhausted else { return }
            skipGroups()
            guard position < entries.count else { return }
            if case .sequence(false, _) = entries[position] {
                position += 1
            }
        }

        /// Count top-level balanced elements from the given position until the matching `.sequence(false)` at depth 0.
        private func countTopLevelElements(from startPos: Int) -> Int? {
            var pos = startPos
            var depth = 0
            var count = 0

            while pos < entries.count {
                switch entries[pos] {
                case .sequence(false, _) where depth == 0:
                    return count
                case .group(true), .sequence(true, _):
                    if depth == 0 { count += 1 }
                    depth += 1
                case .group(false), .sequence(false, _):
                    depth -= 1
                case .value, .reduced, .just:
                    if depth == 0 { count += 1 }
                case .branch:
                    break // Branch markers are inside groups, not standalone
                }
                pos += 1
            }
            return nil // Malformed: no matching close
        }
    }

    struct PrefixContext: ~Copyable {
        var cursor: PrefixCursor
        var prng: Xoshiro256
        var size: UInt64
        var sizeOverride: UInt64?
    }
}

// MARK: - Recursive Engine

private extension PrefixMaterializer {
    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        switch gen {
        case let .pure(value):
            return (value, .emptyJust)

        case let .impure(operation, continuation):
            switch operation {
            case let .contramap(_, nextGen):
                return try handleContramap(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .pick(choices):
                return try handlePick(
                    choices,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .chooseBits(min, max, tag, isRangeExplicit):
                return try handleChooseBits(
                    min: min,
                    max: max,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .zip(generators, _):
                return try handleZip(
                    generators,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .just(value):
                return try runContinuation(
                    result: value,
                    calleeChoiceTree: .just("\(value)"),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case .getSize:
                let size = context.sizeOverride ?? context.size
                context.sizeOverride = nil
                return try runContinuation(
                    result: size,
                    calleeChoiceTree: .getSize(size),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .resize(newSize, gen):
                return try handleResize(
                    newSize: newSize,
                    gen: gen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .filter(gen, _, _, predicate):
                guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context) else {
                    return nil
                }
                guard predicate(result) else {
                    return nil
                }
                return try runContinuation(
                    result: result,
                    calleeChoiceTree: tree,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .classify(gen, _, _):
                guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context) else {
                    return nil
                }
                return try runContinuation(
                    result: result,
                    calleeChoiceTree: tree,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .unique(gen, _, _):
                guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context) else {
                    return nil
                }
                return try runContinuation(
                    result: result,
                    calleeChoiceTree: tree,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            case let .transform(kind, inner):
                guard let (innerValue, innerTree) = try generateRecursive(inner, with: inputValue, context: &context) else {
                    return nil
                }
                let result: Any
                var resultTree = innerTree
                switch kind {
                case let .map(forward, _, _):
                    result = try forward(innerValue)
                case let .bind(forward, _, _):
                    let boundGen = try forward(innerValue)
                    guard let (boundValue, boundTree) = try generateRecursive(boundGen, with: inputValue, context: &context) else {
                        return nil
                    }
                    result = boundValue
                    resultTree = .group([innerTree, boundTree])
                }
                return try runContinuation(
                    result: result,
                    calleeChoiceTree: resultTree,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )
            }
        }
    }

    // MARK: - Run Continuation

    @inline(__always)
    static func runContinuation<Output>(
        result: Any,
        calleeChoiceTree: ChoiceTree,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        let nextGen = try continuation(result)

        if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if let (continuationResult, innerChoiceTree) = try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
        ) {
            if nextGen.isPure {
                return (continuationResult, calleeChoiceTree)
            } else {
                return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
            }
        }
        return nil
    }

    // MARK: - Operation Handlers

    @inline(__always)
    static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(nextGen, with: inputValue, context: &context) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let (result, tree) = try generateRecursive(nextGen, with: wrappedValue, context: &context) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        let randomBits: UInt64

        if let prefixValue = context.cursor.tryConsumeValue() {
            // Clamp the prefix value's bit pattern to the valid range
            let bp = prefixValue.choice.bitPattern64
            randomBits = Swift.min(Swift.max(bp, min), max)
        } else {
            randomBits = context.prng.next(in: min ... max)
        }

        let choiceTree = ChoiceTree.choice(
            ChoiceValue(randomBits, tag: tag),
            .init(validRange: min ... max, isRangeExplicit: isRangeExplicit),
        )
        return try runContinuation(
            result: randomBits,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        let branchIDs = choices.map(\.id)

        let selectedChoice: ReflectiveOperation.PickTuple? = if let prefixBranch = context.cursor.tryConsumeBranch() {
            // Use the branch ID from the prefix to select the choice
            choices.first(where: { $0.id == prefixBranch.id })
        } else {
            WeightedPickSelection.draw(from: choices, using: &context.prng)
        }

        guard let selectedChoice else { return nil }

        // Execute only the selected branch (materializePicks: false)
        guard let (result, branchTree) = try generateRecursive(
            selectedChoice.generator,
            with: inputValue,
            context: &context,
        ) else { return nil }

        guard let (finalValue, contTree) = try runContinuation(
            result: result,
            calleeChoiceTree: branchTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        ) else { return nil }

        let branch = ChoiceTree.branch(
            siteID: selectedChoice.siteID,
            weight: selectedChoice.weight,
            id: selectedChoice.id,
            branchIDs: branchIDs,
            choice: contTree,
        )

        return (finalValue, .group([.selected(branch)]))
    }

    @inline(__always)
    static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        let length: UInt64
        let lengthMeta: ChoiceMetadata

        if let seqInfo = context.cursor.tryConsumeSequenceOpen() {
            // Replaying from prefix: derive length from element count
            length = UInt64(seqInfo.elementCount)
            lengthMeta = ChoiceMetadata(
                validRange: nil,
                isRangeExplicit: seqInfo.isLengthExplicit,
            )
        } else {
            // Cursor exhausted or mismatched — generate fresh
            guard let (l, lt) = try generateRecursive(
                lengthGen,
                with: inputValue,
                context: &context,
            ) else {
                return nil
            }
            length = l
            lengthMeta = lt.metadata
        }

        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(Int(length))
        elements.reserveCapacity(Int(length))

        let didSucceed = try SequenceExecutionKernel.run(count: length) {
            guard let (result, element) = try generateRecursive(elementGen, with: inputValue, context: &context) else {
                return false
            }
            results.append(result)
            elements.append(element)
            return true
        }
        guard didSucceed else {
            return nil
        }

        // Skip past .sequence(false) when replaying from prefix
        context.cursor.skipSequenceClose()

        let choiceTree = ChoiceTree.sequence(
            length: length,
            elements: elements,
            lengthMeta,
        )

        if let (result, _) = try runContinuation(
            result: results,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        ) {
            return (result, choiceTree)
        }
        return nil
    }

    @inline(__always)
    static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        for gen in generators {
            guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context) else {
                return nil
            }
            results.append(result)
            choiceTrees.append(tree)
        }
        return try runContinuation(
            result: results,
            calleeChoiceTree: .group(choiceTrees),
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout PrefixContext,
    ) throws -> (Output, ChoiceTree)? {
        context.sizeOverride = newSize
        guard let result = try generateRecursive(gen, with: inputValue, context: &context) else {
            return nil
        }
        return try runContinuation(
            result: result.0,
            calleeChoiceTree: .resize(newSize: newSize, choices: [result.1]),
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }
}
