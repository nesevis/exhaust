//
//  GuidedMaterializer.swift
//  Exhaust
//

// swiftlint:disable function_parameter_count

/// Interpreter that replays recorded choices where available and generates fresh via PRNG elsewhere.
///
/// Supports three tiers of value selection at each choice point:
/// 1. **Prefix cursor** — consume from the ChoiceSequence (highest priority).
/// 2. **Fallback tree** — extract the value from the corresponding ChoiceTree node.
/// 3. **PRNG** — generate fresh (lowest priority).
///
/// The fallback tree tier is used during shrinking to preserve bound subtree values at their last
/// known-good state instead of randomizing them via PRNG.
public enum GuidedMaterializer {
    /// Result of a guided materialization attempt.
    public enum Result<Output> {
        case success(value: Output, sequence: ChoiceSequence, tree: ChoiceTree)
        case filterEncountered
        case failed
    }

    public static func materialize<Output>(
        _ gen: ReflectiveGenerator<Output>,
        prefix: ChoiceSequence,
        seed: UInt64,
        abortOnFilter: Bool = false,
        fallbackTree: ChoiceTree? = nil,
        maximizeBoundRegionIndices: Set<Int>? = nil,
    ) -> Result<Output> {
        var context = GuidedContext(
            cursor: GuidedCursor(from: prefix),
            prng: Xoshiro256(seed: seed),
            abortOnFilter: abortOnFilter,
            maximizeBoundRegionIndices: maximizeBoundRegionIndices,
        )
        do {
            guard let (value, tree) = try generateRecursive(gen, with: (), context: &context, fallbackTree: fallbackTree) else {
                return .failed
            }
            let sequence = ChoiceSequence(tree)
            return .success(value: value, sequence: sequence, tree: tree)
        } catch is FilterAbort {
            return .filterEncountered
        } catch {
            return .failed
        }
    }

    /// Sentinel error thrown when `abortOnFilter` is set and a filter is encountered.
    struct FilterAbort: Error {}
}

// MARK: - Recursive Engine

private extension GuidedMaterializer {
    /// Describes the callee tree shape produced by an operation, used by ``decomposeFallback``
    /// to distinguish a data group (e.g. zip's children) from a continuation-wrapped tree.
    enum CalleeTreeKind {
        /// Operations whose callee tree is never a `.group`: chooseBits, pick, bind, sequence, etc.
        /// A 2-child `.group` unambiguously indicates `[callee, continuation]` wrapping.
        case nonGroup
        /// Zip: callee tree is `.group(children)` with a known child count.
        /// Disambiguates by checking whether the first child is itself a `.group` matching
        /// the expected child count (indicating continuation wrapping).
        case group(childCount: Int)
        /// Contramap / map: tree-transparent — no callee tree node of their own.
        /// The full fallback belongs to the inner generator.
        case transparent
    }

    /// Split a fallback tree into the callee portion and continuation portion.
    ///
    /// `runContinuation` builds trees as:
    /// - Pure continuation: returns `calleeTree` (no wrapping)
    /// - Non-pure continuation: returns `.group([calleeTree, continuationTree])`
    ///
    /// The `calleeKind` parameter tells us the callee tree shape so we can avoid
    /// misinterpreting a data group (e.g. zip of 2 generators) as continuation wrapping.
    static func decomposeFallback(
        _ tree: ChoiceTree?,
        calleeKind: CalleeTreeKind
    ) -> (callee: ChoiceTree?, continuation: ChoiceTree?) {
        guard let tree else { return (nil, nil) }
        switch calleeKind {
        case .transparent:
            // Transparent operations don't produce a tree node.
            // The full fallback belongs to the inner generator.
            return (tree, nil)

        case .nonGroup:
            // Callee is never a group, so a 2-child group is always continuation wrapping.
            if case let .group(children, _) = tree, children.count == 2 {
                return (children[0], children[1])
            }
            return (tree, nil)

        case let .group(childCount):
            // Zip's callee tree is .group(children) with children.count == childCount.
            // Continuation wrapping would be .group([zip_callee_group, cont]).
            if case let .group(children, _) = tree, children.count == 2,
               case let .group(inner, _) = children[0], inner.count == childCount
            {
                // First child is a group matching the expected callee shape → continuation wrapped.
                return (children[0], children[1])
            }
            // Otherwise the tree IS the callee (pure continuation, or no wrapping).
            return (tree, nil)
        }
    }

    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout GuidedContext,
        fallbackTree: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        switch gen {
        case let .pure(value):
            return (value, .emptyJust)

        case let .impure(operation, continuation):
            let calleeKind: CalleeTreeKind
            switch operation {
            case .contramap:
                calleeKind = .transparent
            case let .transform(kind, _):
                switch kind {
                case .map: calleeKind = .transparent
                case .bind: calleeKind = .nonGroup
                }
            case let .zip(generators, _):
                calleeKind = .group(childCount: generators.count)
            default:
                calleeKind = .nonGroup
            }
            let (calleeFallback, continuationFallback) = decomposeFallback(fallbackTree, calleeKind: calleeKind)

            switch operation {
            case let .contramap(_, nextGen):
                return try handleContramap(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
                )

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
                )

            case let .pick(choices):
                return try handlePick(
                    choices,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
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
                    calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
                )

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
                )

            case let .zip(generators, _):
                return try handleZip(
                    generators,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
                )

            case let .just(value):
                return try runContinuation(
                    result: value,
                    calleeChoiceTree: .just("\(value)"),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    continuationFallback: continuationFallback,
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
                    continuationFallback: continuationFallback,
                )

            case let .resize(newSize, gen):
                return try handleResize(
                    newSize: newSize,
                    gen: gen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
                )

            case let .filter(gen, _, _, predicate):
                if context.abortOnFilter {
                    throw FilterAbort()
                }
                guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context, fallbackTree: calleeFallback) else {
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
                    continuationFallback: continuationFallback,
                )

            case let .classify(gen, _, _):
                guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context, fallbackTree: calleeFallback) else {
                    return nil
                }
                return try runContinuation(
                    result: result,
                    calleeChoiceTree: tree,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    continuationFallback: continuationFallback,
                )

            case let .unique(gen, _, _):
                guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context, fallbackTree: calleeFallback) else {
                    return nil
                }
                return try runContinuation(
                    result: result,
                    calleeChoiceTree: tree,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    continuationFallback: continuationFallback,
                )

            case let .transform(kind, inner):
                switch kind {
                case let .map(forward, _, _):
                    guard let (innerValue, innerTree) = try generateRecursive(inner, with: inputValue, context: &context, fallbackTree: calleeFallback) else {
                        return nil
                    }
                    let result = try forward(innerValue)
                    return try runContinuation(
                        result: result,
                        calleeChoiceTree: innerTree,
                        continuation: continuation,
                        inputValue: inputValue,
                        context: &context,
                        continuationFallback: continuationFallback,
                    )
                case let .bind(forward, _, _, _):
                    let innerFallback: ChoiceTree?
                    let boundFallback: ChoiceTree?
                    if let calleeFallback, case let .bind(inner: iFB, bound: bFB) = calleeFallback {
                        innerFallback = iFB
                        boundFallback = bFB
                    } else {
                        innerFallback = nil
                        boundFallback = nil
                    }
                    guard let (innerValue, innerTree) = try generateRecursive(inner, with: inputValue, context: &context, fallbackTree: innerFallback) else {
                        return nil
                    }
                    let boundGen = try forward(innerValue)
                    // Skip past the bind's bound content in the prefix and suspend prefix consumption.
                    // The bound subtree now falls back to the fallback tree instead of pure PRNG.
                    context.cursor.skipBindBound()
                    context.cursor.suspendForBind()
                    let boundResult = try generateRecursive(boundGen, with: inputValue, context: &context, fallbackTree: boundFallback)
                    context.cursor.resumeAfterBind()
                    guard let (boundValue, boundTree) = boundResult else {
                        return nil
                    }
                    return try runContinuation(
                        result: boundValue,
                        calleeChoiceTree: .bind(inner: innerTree, bound: boundTree),
                        continuation: continuation,
                        inputValue: inputValue,
                        context: &context,
                        continuationFallback: continuationFallback,
                    )
                }
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
        context: inout GuidedContext,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        let nextGen = try continuation(result)

        if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if let (continuationResult, innerChoiceTree) = try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
            fallbackTree: continuationFallback,
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
        context: inout GuidedContext,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(nextGen, with: inputValue, context: &context, fallbackTree: calleeFallback) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: continuationFallback,
        )
    }

    @inline(__always)
    static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GuidedContext,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let (result, tree) = try generateRecursive(nextGen, with: wrappedValue, context: &context, fallbackTree: calleeFallback) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: continuationFallback,
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
        context: inout GuidedContext,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        let randomBits: UInt64

        if let prefixValue = context.cursor.tryConsumeValue() {
            // Clamp the prefix value's bit pattern to the valid range
            let bp = prefixValue.choice.bitPattern64
            randomBits = Swift.min(Swift.max(bp, min), max)
        } else if let indices = context.maximizeBoundRegionIndices,
                  context.cursor.isSuspended,
                  indices.contains(context.cursor.bindEncounterCount - 1) {
            // Maximize: use upper bound for this bind region's bound values.
            // bindEncounterCount is 1-based (incremented on suspendForBind), so subtract 1
            // to get the 0-based region index matching BindSpanIndex.regions ordering.
            randomBits = max
        } else if let calleeFallback, case let .choice(value, _) = calleeFallback {
            // Fallback: use tree value, clamped to valid range
            randomBits = Swift.min(Swift.max(value.bitPattern64, min), max)
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
            continuationFallback: continuationFallback,
        )
    }

    @inline(__always)
    static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GuidedContext,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        let branchIDs = choices.map(\.id)

        // Extract branch fallback info from calleeFallback
        let fbBranchId: UInt64?
        let branchChoiceTree: ChoiceTree?
        if let calleeFallback,
           case let .group(children, _) = calleeFallback,
           let selected = children.first,
           case let .selected(inner) = selected,
           case let .branch(_, _, id, _, choice) = inner
        {
            fbBranchId = id
            branchChoiceTree = choice
        } else {
            fbBranchId = nil
            branchChoiceTree = nil
        }

        let selectedChoice: ReflectiveOperation.PickTuple? = if let prefixBranch = context.cursor.tryConsumeBranch() {
            // Use the branch ID from the prefix to select the choice
            choices.first(where: { $0.id == prefixBranch.id })
        } else if let fbBranchId {
            choices.first(where: { $0.id == fbBranchId })
        } else {
            WeightedPickSelection.draw(from: choices, using: &context.prng)
        }

        guard let selectedChoice else { return nil }

        // Decompose branch choice tree into body and continuation fallbacks.
        // The branch body generator's callee kind is unknown; .nonGroup is the
        // conservative default (matches prior behaviour).
        let (branchBodyFallback, branchContFallback) = decomposeFallback(branchChoiceTree, calleeKind: .nonGroup)

        // Execute only the selected branch (materializePicks: false)
        guard let (result, branchTree) = try generateRecursive(
            selectedChoice.generator,
            with: inputValue,
            context: &context,
            fallbackTree: branchBodyFallback,
        ) else { return nil }

        guard let (finalValue, contTree) = try runContinuation(
            result: result,
            calleeChoiceTree: branchTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: branchContFallback ?? continuationFallback,
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
        context: inout GuidedContext,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        let length: UInt64
        let lengthMeta: ChoiceMetadata
        var elementFallbacks: [ChoiceTree]?

        // Extract element fallbacks from the fallback tree. The sequence LENGTH is always
        // determined by the generator (not the tree) so that bound generators whose length
        // depends on the inner value produce the correct count.
        if let calleeFallback, case let .sequence(_, fbElements, _) = calleeFallback {
            elementFallbacks = fbElements
        }

        if let seqInfo = context.cursor.tryConsumeSequenceOpen() {
            if seqInfo.isLengthExplicit {
                // Explicit-length sequence (e.g. .array(length: 2)): the generator
                // determines the count, not the prefix. Deletion tactics may remove
                // elements from the prefix, but the generator's fixed length is
                // authoritative. Elements beyond the prefix are filled from fallback/PRNG.
                guard let (genLength, lengthTree) = try generateRecursive(
                    lengthGen,
                    with: inputValue,
                    context: &context,
                ) else {
                    return nil
                }
                length = genLength
                lengthMeta = lengthTree.metadata
            } else {
                // Variable-length sequence: derive from prefix element count
                length = UInt64(seqInfo.elementCount)
                lengthMeta = ChoiceMetadata(
                    validRange: nil,
                    isRangeExplicit: false,
                )
            }
        } else {
            // Cursor exhausted or mismatched — generate fresh
            guard let (freshLength, lengthTree) = try generateRecursive(
                lengthGen,
                with: inputValue,
                context: &context,
            ) else {
                return nil
            }
            length = freshLength
            lengthMeta = lengthTree.metadata
        }

        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(Int(length))
        elements.reserveCapacity(Int(length))

        var elementIndex = 0
        let didSucceed = try SequenceExecutionKernel.run(count: length) {
            let elFB = elementFallbacks.flatMap { $0.indices.contains(elementIndex) ? $0[elementIndex] : nil }
            guard let (result, element) = try generateRecursive(elementGen, with: inputValue, context: &context, fallbackTree: elFB) else {
                return false
            }
            results.append(result)
            elements.append(element)
            elementIndex += 1
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
            continuationFallback: continuationFallback,
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
        context: inout GuidedContext,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        let childFallbacks: [ChoiceTree?]
        if let calleeFallback, case let .group(children, _) = calleeFallback,
           children.count == generators.count
        {
            childFallbacks = children.map { Optional($0) }
        } else {
            childFallbacks = Array(repeating: nil, count: generators.count)
        }

        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        // When a fallback tree is available, scope the cursor per child so that
        // deleted children don't cause the cursor to consume a sibling's entries.
        // Each child gets at most as many entries as its fallback tree would produce
        // when flattened. Without a fallback tree, no scoping is applied — the cursor
        // consumes entries freely (normal generation/replay behavior).
        //
        // After each child, childStartPosition advances to the cursor's *actual*
        // position — not the fallback-derived span. When a child was deleted from
        // the prefix, its entries are shorter than the fallback span, and subsequent
        // children's scopes must start from the actual cursor position.
        let canScope = childFallbacks.contains(where: { $0 != nil })
        var childStartPosition = context.cursor.position
        for (gen, fb) in zip(generators, childFallbacks) {
            if canScope, let fb {
                context.cursor.pushScope(limit: childStartPosition + fb.flattenedEntryCount)
            }
            guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context, fallbackTree: fb) else {
                if canScope, fb != nil { context.cursor.popScope() }
                return nil
            }
            if canScope, fb != nil { context.cursor.popScope() }
            childStartPosition = context.cursor.position
            results.append(result)
            choiceTrees.append(tree)
        }
        return try runContinuation(
            result: results,
            calleeChoiceTree: .group(choiceTrees),
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: continuationFallback,
        )
    }

    @inline(__always)
    static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GuidedContext,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
    ) throws -> (Output, ChoiceTree)? {
        let innerFallback: ChoiceTree?
        if let calleeFallback, case let .resize(_, choices) = calleeFallback, let inner = choices.first {
            innerFallback = inner
        } else {
            innerFallback = nil
        }
        context.sizeOverride = newSize
        guard let result = try generateRecursive(gen, with: inputValue, context: &context, fallbackTree: innerFallback) else {
            return nil
        }
        return try runContinuation(
            result: result.0,
            calleeChoiceTree: .resize(newSize: newSize, choices: [result.1]),
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: continuationFallback,
        )
    }
}

// MARK: - Internal State

private extension GuidedMaterializer {
    /// Position-based cursor that traverses the full `ChoiceSequence` including structural markers (`.group`, `.sequence`).
    ///
    /// Group markers (from `runContinuation` grouping and pick sites) are transparently skipped. Sequence markers are handled explicitly by `tryConsumeSequenceOpen()` / `skipSequenceClose()`.
    struct GuidedCursor: ~Copyable {
        private let entries: ChoiceSequence
        private(set) var position: Int = 0
        var exhausted: Bool = false
        /// When > 0, the cursor is inside a bind's bound subtree and should
        /// behave as exhausted so GuidedMaterializer falls back to PRNG.
        private var bindSuspendDepth: Int = 0
        /// Stack of position limits for nested scopes (zip children).
        /// When non-empty, the cursor reports exhausted at the topmost limit.
        private var scopeLimits: [Int] = []

        init(from sequence: ChoiceSequence) {
            entries = sequence
        }

        /// Pushes a scope limit: the cursor will report exhausted at `limit`.
        /// Used by the zip handler to prevent one child from consuming a sibling's entries.
        mutating func pushScope(limit: Int) {
            scopeLimits.append(limit)
        }

        /// Pops the most recent scope limit.
        mutating func popScope() {
            scopeLimits.removeLast()
        }

        /// The effective end position: min of sequence length and topmost scope limit.
        private var effectiveEnd: Int {
            if let limit = scopeLimits.last {
                return min(entries.count, limit)
            }
            return entries.count
        }

        /// Skip consecutive `.group(true/false)` and `.just` markers at the current position.
        /// Groups are transparent wrappers from `runContinuation` and pick sites.
        /// Just markers carry no data and are purely structural.
        private mutating func skipGroups() {
            while position < effectiveEnd {
                switch entries[position] {
                case .group, .bind, .just:
                    position += 1
                default:
                    return
                }
            }
        }

        /// Advance the cursor past the bound content of a `.bind` node.
        ///
        /// After inner content has been consumed, the cursor sits somewhere inside the
        /// bind's span. This method scans forward to the matching `.bind(false)` marker,
        /// skipping nested bind/group/sequence structures, so that subsequent prefix
        /// entries (e.g. sibling parameters in a zip) are correctly aligned.
        mutating func skipBindBound() {
            var depth = 0
            while position < effectiveEnd {
                switch entries[position] {
                case .bind(true):
                    depth += 1
                    position += 1
                case .bind(false):
                    if depth == 0 {
                        // Found the outer bind-close; skip it and stop.
                        position += 1
                        return
                    }
                    depth -= 1
                    position += 1
                default:
                    position += 1
                }
            }
        }

        /// Total number of bind suspensions entered (monotonically increasing).
        /// Used by ``maximizeBoundRegionIndices`` to identify which bind region we're inside.
        private(set) var bindEncounterCount: Int = 0

        /// Suspend prefix consumption so the cursor reports exhausted.
        /// Used when generating a bind's bound subtree via PRNG.
        mutating func suspendForBind() {
            bindSuspendDepth += 1
            bindEncounterCount += 1
        }

        /// Resume prefix consumption after the bound subtree has been generated.
        mutating func resumeAfterBind() {
            bindSuspendDepth -= 1
        }

        var isSuspended: Bool { bindSuspendDepth > 0 }

        mutating func tryConsumeValue() -> ChoiceSequenceValue.Value? {
            guard !exhausted, !isSuspended else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
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
            guard !exhausted, !isSuspended else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
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
            guard !exhausted, !isSuspended else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
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
            guard position < effectiveEnd else { return }
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
                case .group(true), .bind(true), .sequence(true, _):
                    if depth == 0 { count += 1 }
                    depth += 1
                case .group(false), .bind(false), .sequence(false, _):
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

    struct GuidedContext: ~Copyable {
        var cursor: GuidedCursor
        var prng: Xoshiro256
        var size: UInt64 = GenerationContext.scaledSize(forRun: 0)
        var sizeOverride: UInt64?
        var abortOnFilter: Bool = false
        var maximizeBoundRegionIndices: Set<Int>? = nil
    }
}
