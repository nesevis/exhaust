//
//  ReductionMaterializer.swift
//  Exhaust
//

// swiftlint:disable function_parameter_count

/// Materializer that always produces a fresh ``ChoiceTree`` with current ``validRange`` metadata
/// and all branch alternatives at pick sites.
///
/// Unlike the legacy ``Interpreters.materialize()`` + ``GuidedMaterializer`` path, this materializer:
/// - Rebuilds the tree from the generator on every invocation (no stale metadata).
/// - Materializes all branch alternatives at pick sites (``PromoteBranchesEncoder`` sees candidates).
/// - Supports exact and guided modes with inner-reject/bound-clamp semantics.
///
/// The result intentionally omits ``ChoiceSequence`` — the caller flattens `result.tree` to get a sequence with fresh metadata. The tree is the single source of truth.
public enum ReductionMaterializer {
    /// Controls how values are resolved at each choice point.
    public enum Mode {
        /// Replay all values from prefix. Reject out-of-range inner values, clamp bound values.
        /// No cursor suspension for binds.
        case exact

        /// Three-tiered resolution: prefix → fallback → PRNG. Clamp to range. Cursor suspension
        /// at bind sites.
        case guided(seed: UInt64, fallbackTree: ChoiceTree?,
                    maximizeBoundRegionIndices: Set<Int>? = nil)
    }

    /// Result of a reduction materialization attempt.
    public enum Result<Output> {
        /// Materialization succeeded with a value and fresh tree.
        case success(value: Output, tree: ChoiceTree)
        /// Exact mode: out-of-range or structural mismatch — candidate is invalid.
        case rejected
        /// Guided mode: filter or generation failure.
        case failed
    }

    /// Materialize a generator using the given prefix and mode.
    ///
    /// - Parameters:
    ///   - gen: The generator to materialize.
    ///   - prefix: The choice sequence to replay from.
    ///   - mode: How to resolve values at each choice point.
    /// - Returns: A ``Result`` containing the output value and fresh tree on success.
    public static func materialize<Output>(
        _ gen: ReflectiveGenerator<Output>,
        prefix: consuming ChoiceSequence,
        mode: Mode,
        fallbackTree: ChoiceTree? = nil,
        materializePicks: Bool = true
    ) -> Result<Output> {
        let seed: UInt64
        let resolvedFallbackTree: ChoiceTree?
        let maximizeBoundRegionIndices: Set<Int>?

        switch mode {
        case .exact:
            seed = ZobristHash.hash(of: prefix)
            // In exact mode, the fallback tree is used for `.getSize` extraction only,
            // not for value fallback (all values come from the prefix).
            resolvedFallbackTree = fallbackTree
            maximizeBoundRegionIndices = nil
        case let .guided(s, fb, indices):
            seed = s
            resolvedFallbackTree = fb ?? fallbackTree
            maximizeBoundRegionIndices = indices
        }

        var context = Context(
            cursor: Cursor(from: consume prefix),
            prng: Xoshiro256(seed: seed),
            mode: mode.internalMode,
            // Use max size (100) so size-scaled generators produce their full range.
            // Size 1 (scaledSize(forRun: 0)) would produce tiny ranges that reject
            // or clamp valid values from larger-size generations.
            size: 100,
            maximizeBoundRegionIndices: maximizeBoundRegionIndices,
            materializePicks: materializePicks
        )

        do {
            guard let (value, tree) = try generateRecursive(
                gen, with: (), context: &context, fallbackTree: resolvedFallbackTree
            ) else {
                switch mode {
                case .exact: return .rejected
                case .guided: return .failed
                }
            }
            return .success(value: value, tree: tree)
        } catch is RejectionError {
            return .rejected
        } catch {
            return .failed
        }
    }
}

// MARK: - Internal Types

private extension ReductionMaterializer {
    /// Sentinel thrown when exact mode encounters an out-of-range inner value or exhausted prefix.
    struct RejectionError: Error {}

    /// Internal mode enum — includes `.generate` for non-selected branch materialization.
    enum InternalMode {
        /// Exact: reject out-of-range inner values, clamp bound values, no cursor suspension.
        case exact
        /// Guided: tiered resolution (prefix → fallback → PRNG), cursor suspension at binds.
        case guided
        /// Pure PRNG generation — used for non-selected branches at pick sites.
        case generate
    }
}

private extension ReductionMaterializer.Mode {
    var internalMode: ReductionMaterializer.InternalMode {
        switch self {
        case .exact: .exact
        case .guided: .guided
        }
    }
}

// MARK: - Recursive Engine

private extension ReductionMaterializer {
    /// Split a fallback tree into callee and continuation portions for non-group operations.
    @inline(__always)
    static func decomposeNonGroupFallback(
        _ tree: ChoiceTree?
    ) -> (callee: ChoiceTree?, continuation: ChoiceTree?) {
        guard let tree else { return (nil, nil) }
        if case let .group(children, _) = tree, children.count == 2 {
            return (children[0], children[1])
        }
        return (tree, nil)
    }

    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout Context,
        fallbackTree: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        switch gen {
        case let .pure(value):
            return (value, .emptyJust)

        case let .impure(operation, continuation):
            switch operation {
            case let .contramap(_, nextGen):
                // Transparent: no callee tree node — fallback passes through.
                return try handleContramap(
                    nextGen, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: fallbackTree,
                    continuationFallback: nil
                )

            case let .prune(nextGen):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handlePrune(
                    nextGen, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .pick(choices):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handlePick(
                    choices, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .chooseBits(min, max, tag, isRangeExplicit):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handleChooseBits(
                    min: min, max: max, tag: tag, isRangeExplicit: isRangeExplicit,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .sequence(lengthGen, elementGen):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handleSequence(
                    lengthGen: lengthGen, elementGen: elementGen,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .zip(generators, _):
                // Zip: callee is a group with known child count.
                let (calleeFallback, continuationFallback): (ChoiceTree?, ChoiceTree?)
                if let fallbackTree,
                   case let .group(children, _) = fallbackTree, children.count == 2,
                   case let .group(inner, _) = children[0], inner.count == generators.count
                {
                    (calleeFallback, continuationFallback) = (children[0], children[1])
                } else {
                    (calleeFallback, continuationFallback) = (fallbackTree, nil)
                }
                return try handleZip(
                    generators, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .just(value):
                let (_, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try runContinuation(
                    result: value, calleeChoiceTree: .just("\(value)"),
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case .getSize:
                // Always use context.size (default 100 = max). At max size, all
                // size-scaled generators produce their full range, so no valid
                // prefix value is ever outside the derived range. Using the
                // fallback tree's `.getSize` is unreliable — reflected trees may
                // store a small size that produces tiny ranges, destroying values
                // via clamping.
                let (_, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                let size = context.sizeOverride ?? context.size
                context.sizeOverride = nil
                return try runContinuation(
                    result: size, calleeChoiceTree: .getSize(size),
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case let .resize(newSize, gen):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handleResize(
                    newSize: newSize, gen: gen,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .filter(gen, _, _, predicate):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                guard let (result, tree) = try generateRecursive(
                    gen, with: inputValue, context: &context, fallbackTree: calleeFallback
                ) else { return nil }
                guard predicate(result) else { return nil }
                return try runContinuation(
                    result: result, calleeChoiceTree: tree,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case let .classify(gen, _, _):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                guard let (result, tree) = try generateRecursive(
                    gen, with: inputValue, context: &context, fallbackTree: calleeFallback
                ) else { return nil }
                return try runContinuation(
                    result: result, calleeChoiceTree: tree,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case let .unique(gen, _, _):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                guard let (result, tree) = try generateRecursive(
                    gen, with: inputValue, context: &context, fallbackTree: calleeFallback
                ) else { return nil }
                return try runContinuation(
                    result: result, calleeChoiceTree: tree,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case let .transform(kind, inner):
                switch kind {
                case .map:
                    // Transparent: no callee tree node — fallback passes through.
                    return try handleTransform(
                        kind: kind, inner: inner,
                        continuation: continuation, inputValue: inputValue,
                        context: &context, calleeFallback: fallbackTree,
                        continuationFallback: nil
                    )
                case .bind:
                    let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                    return try handleTransform(
                        kind: kind, inner: inner,
                        continuation: continuation, inputValue: inputValue,
                        context: &context, calleeFallback: calleeFallback,
                        continuationFallback: continuationFallback
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
        context: inout Context,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        let nextGen = try continuation(result)

        if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if let (continuationResult, innerChoiceTree) = try generateRecursive(
            nextGen, with: inputValue, context: &context,
            fallbackTree: continuationFallback
        ) {
            if nextGen.isPure {
                return (continuationResult, calleeChoiceTree)
            } else {
                return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
            }
        }
        return nil
    }
}

// MARK: - Operation Handlers

private extension ReductionMaterializer {
    @inline(__always)
    static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(
            nextGen, with: inputValue, context: &context, fallbackTree: calleeFallback
        ) else { return nil }
        return try runContinuation(
            result: result, calleeChoiceTree: tree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    @inline(__always)
    static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let (result, tree) = try generateRecursive(
            nextGen, with: wrappedValue, context: &context, fallbackTree: calleeFallback
        ) else { return nil }
        return try runContinuation(
            result: result, calleeChoiceTree: tree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: chooseBits

    @inline(__always)
    static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        let randomBits: UInt64
        var reusedChoice: ChoiceValue?

        switch context.mode {
        case .exact:
            guard let prefixValue = context.cursor.tryConsumeValue() else {
                throw RejectionError()
            }
            let bp = prefixValue.choice.bitPattern64
            if context.boundDepth > 0 || isRangeExplicit == false {
                // Bound value or non-explicit range: clamp to fresh range.
                // Bound ranges may shift when inner values change.
                // Non-explicit ranges (from size scaling) are context-dependent —
                // the generator may derive a narrower range than the original, so
                // clamping is safer than rejecting.
                randomBits = Swift.min(Swift.max(bp, min), max)
            } else {
                // Explicit-range inner value: reject if out of range.
                guard bp >= min, bp <= max else {
                    throw RejectionError()
                }
                randomBits = bp
            }
            // Reuse original ChoiceValue when bits unchanged, avoiding
            // tag.makeConvertible(bitPattern64:) reconstruction.
            if randomBits == bp {
                reusedChoice = prefixValue.choice
            }

        case .guided:
            if let prefixValue = context.cursor.tryConsumeValue() {
                let bp = prefixValue.choice.bitPattern64
                randomBits = Swift.min(Swift.max(bp, min), max)
                if randomBits == bp {
                    reusedChoice = prefixValue.choice
                }
            } else if let indices = context.maximizeBoundRegionIndices,
                      context.cursor.isSuspended,
                      indices.contains(context.cursor.bindEncounterCount - 1)
            {
                randomBits = max
            } else if let calleeFallback, case let .choice(value, _) = calleeFallback {
                randomBits = Swift.min(Swift.max(value.bitPattern64, min), max)
            } else {
                randomBits = context.prng.next(in: min ... max)
            }

        case .generate:
            randomBits = context.prng.next(in: min ... max)
        }

        let choice = reusedChoice ?? ChoiceValue(randomBits, tag: tag)
        let choiceTree = ChoiceTree.choice(
            choice,
            .init(validRange: min ... max, isRangeExplicit: isRangeExplicit)
        )
        return try runContinuation(
            result: randomBits, calleeChoiceTree: choiceTree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: pick (with materialized alternatives)

    @inline(__always)
    static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        // Always consume a jump seed from the PRNG stream (VACTI pattern).
        let jumpSeed = context.prng.next()
        var branchIDs = [UInt64]()
        branchIDs.reserveCapacity(choices.count)
        var branchIDIdx = 0
        while branchIDIdx < choices.count {
            branchIDs.append(choices[branchIDIdx].id)
            branchIDIdx += 1
        }

        // Extract fallback branch info.
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

        // Select branch based on mode.
        let selectedChoice: ReflectiveOperation.PickTuple?
        switch context.mode {
        case .exact:
            guard let prefixBranch = context.cursor.tryConsumeBranch() else {
                throw RejectionError()
            }
            selectedChoice = choices.first(where: { $0.id == prefixBranch.id })

        case .guided:
            if let prefixBranch = context.cursor.tryConsumeBranch() {
                selectedChoice = choices.first(where: { $0.id == prefixBranch.id })
            } else if let fbBranchId {
                selectedChoice = choices.first(where: { $0.id == fbBranchId })
            } else {
                selectedChoice = WeightedPickSelection.draw(from: choices, using: &context.prng)
            }

        case .generate:
            selectedChoice = WeightedPickSelection.draw(from: choices, using: &context.prng)
        }

        guard let selectedChoice else { return nil }

        // Decompose branch choice tree for selected branch fallback.
        let (branchBodyFallback, branchContFallback) = decomposeNonGroupFallback(
            branchChoiceTree
        )

        // Execute selected branch; optionally materialize non-selected branches.
        var branches = [ChoiceTree]()
        branches.reserveCapacity(context.materializePicks ? choices.count : 1)
        var finalValue: Output?

        if context.materializePicks {
            // Pre-compute selected index to avoid per-iteration ID comparison.
            var selectedIndex = 0
            while selectedIndex < choices.count {
                if choices[selectedIndex].id == selectedChoice.id { break }
                selectedIndex += 1
            }

            var choiceIdx = 0
            while choiceIdx < choices.count {
                let choice = choices[choiceIdx]

                if choiceIdx == selectedIndex {
                    guard let (result, branchTree) = try generateRecursive(
                        choice.generator, with: inputValue, context: &context,
                        fallbackTree: branchBodyFallback
                    ) else { return nil }

                    guard let (contValue, contTree) = try runContinuation(
                        result: result, calleeChoiceTree: branchTree,
                        continuation: continuation, inputValue: inputValue,
                        context: &context,
                        continuationFallback: branchContFallback ?? continuationFallback
                    ) else { return nil }

                    finalValue = contValue
                    branches.append(.selected(.branch(
                        siteID: choice.siteID, weight: choice.weight,
                        id: choice.id, branchIDs: branchIDs, choice: contTree
                    )))
                } else {
                    // Non-selected branch: generate fresh via jumped PRNG.
                    var branchContext = Context(
                        cursor: Cursor.empty,
                        prng: Xoshiro256(seed: jumpSeed),
                        mode: .generate,
                        size: context.size
                    )
                    if let (result, branchTree) = try generateRecursive(
                        choice.generator, with: inputValue, context: &branchContext,
                        fallbackTree: nil
                    ),
                        let (_, contTree) = try runContinuation(
                            result: result, calleeChoiceTree: branchTree,
                            continuation: continuation, inputValue: inputValue,
                            context: &branchContext, continuationFallback: nil
                        )
                    {
                        branches.append(.branch(
                            siteID: choice.siteID, weight: choice.weight,
                            id: choice.id, branchIDs: branchIDs, choice: contTree
                        ))
                    }
                }
                choiceIdx += 1
            }
        } else {
            // Skip non-selected branches — only materialize the selected one.
            guard let (result, branchTree) = try generateRecursive(
                selectedChoice.generator, with: inputValue, context: &context,
                fallbackTree: branchBodyFallback
            ) else { return nil }

            guard let (contValue, contTree) = try runContinuation(
                result: result, calleeChoiceTree: branchTree,
                continuation: continuation, inputValue: inputValue,
                context: &context,
                continuationFallback: branchContFallback ?? continuationFallback
            ) else { return nil }

            finalValue = contValue
            branches.append(.selected(.branch(
                siteID: selectedChoice.siteID, weight: selectedChoice.weight,
                id: selectedChoice.id, branchIDs: branchIDs, choice: contTree
            )))
        }

        guard let value = finalValue else { return nil }
        return (value, .group(branches))
    }

    // MARK: sequence

    @inline(__always)
    static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        let length: UInt64
        let lengthMeta: ChoiceMetadata
        var elementFallbacks: [ChoiceTree]?

        if let calleeFallback, case let .sequence(_, fbElements, _) = calleeFallback {
            elementFallbacks = fbElements
        }

        if let seqInfo = context.cursor.tryConsumeSequenceOpen() {
            if seqInfo.isLengthExplicit, context.mode == .exact {
                // Exact mode + explicit-length: the prefix is authoritative.
                // The length value is not stored in the flattened sequence, so we
                // can't consume it from the cursor. Use the prefix element count.
                length = UInt64(seqInfo.elementCount)
                // Fast path: extract metadata directly from chooseBits length generators
                // (the common case, e.g. `array(length: 0...10)`), avoiding a full
                // generateRecursive + runContinuation round-trip.
                if case let .impure(.chooseBits(min, max, _, isRangeExplicit), _) = lengthGen {
                    lengthMeta = ChoiceMetadata(validRange: min ... max, isRangeExplicit: isRangeExplicit)
                } else {
                    let savedMode = context.mode
                    context.mode = .generate
                    if let (_, lengthTree) = try generateRecursive(
                        lengthGen, with: inputValue, context: &context
                    ) {
                        lengthMeta = lengthTree.metadata
                    } else {
                        lengthMeta = ChoiceMetadata(validRange: nil, isRangeExplicit: true)
                    }
                    context.mode = savedMode
                }
            } else if seqInfo.isLengthExplicit {
                // Guided/generate mode + explicit-length: the generator determines
                // the count. Deletion may remove elements from the prefix, but the
                // generator's fixed length is authoritative (e.g. `exactly: 2` must
                // produce 2). Elements beyond the prefix are filled from fallback/PRNG.
                // Run in `.generate` mode so it doesn't consume cursor entries.
                let savedMode = context.mode
                context.mode = .generate
                guard let (genLength, lengthTree) = try generateRecursive(
                    lengthGen, with: inputValue, context: &context
                ) else {
                    context.mode = savedMode
                    return nil
                }
                context.mode = savedMode
                length = genLength
                lengthMeta = lengthTree.metadata
            } else {
                // Variable-length (non-explicit): derive from prefix element count.
                length = UInt64(seqInfo.elementCount)
                lengthMeta = ChoiceMetadata(validRange: nil, isRangeExplicit: false)
            }
        } else if context.mode == .exact {
            // Exact mode: prefix exhausted or structural mismatch at sequence site.
            throw RejectionError()
        } else {
            guard let (freshLength, lengthTree) = try generateRecursive(
                lengthGen, with: inputValue, context: &context
            ) else { return nil }
            length = freshLength
            lengthMeta = lengthTree.metadata
        }

        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(Int(length))
        elements.reserveCapacity(Int(length))

        var elementIndex = 0
        var remaining = length
        while remaining > 0 {
            let elFB: ChoiceTree? = if let fbs = elementFallbacks, elementIndex < fbs.count {
                fbs[elementIndex]
            } else {
                nil
            }
            guard let (result, element) = try generateRecursive(
                elementGen, with: inputValue, context: &context, fallbackTree: elFB
            ) else { return nil }
            results.append(result)
            elements.append(element)
            elementIndex += 1
            remaining -= 1
        }

        context.cursor.skipSequenceClose()

        let choiceTree = ChoiceTree.sequence(
            length: length, elements: elements, lengthMeta
        )

        if let (result, _) = try runContinuation(
            result: results, calleeChoiceTree: choiceTree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        ) {
            return (result, choiceTree)
        }
        return nil
    }

    // MARK: zip

    @inline(__always)
    static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        let fallbackChildren: [ChoiceTree]? = if let calleeFallback, case let .group(children, _) = calleeFallback,
                                                 children.count == generators.count
        {
            children
        } else {
            nil
        }

        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        let canScope = fallbackChildren != nil
        // Skip transparent markers (group/bind/just) so childStartPosition
        // is past the parent's group-open marker. Without this, the scope
        // limit for the first child is too tight by the number of skipped
        // markers, leaving the child's sequence-close outside the scope.
        // The unconsumed close marker then blocks the next child's open.
        if canScope { context.cursor.skipGroups() }
        var childStartPosition = context.cursor.position
        // while-loop: avoiding zip/IteratorProtocol overhead in debug builds.
        var zipIndex = 0
        while zipIndex < generators.count {
            let gen = generators[zipIndex]
            let fb: ChoiceTree? = fallbackChildren?[zipIndex]
            if canScope, let fb {
                context.cursor.pushScope(limit: childStartPosition + fb.flattenedEntryCount)
            }
            guard let (result, tree) = try generateRecursive(
                gen, with: inputValue, context: &context, fallbackTree: fb
            ) else {
                if canScope, fb != nil { context.cursor.popScope() }
                return nil
            }
            if canScope, fb != nil { context.cursor.popScope() }
            childStartPosition = context.cursor.position
            results.append(result)
            choiceTrees.append(tree)
            zipIndex += 1
        }
        return try runContinuation(
            result: results, calleeChoiceTree: .group(choiceTrees),
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: resize

    @inline(__always)
    static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        let innerFallback: ChoiceTree? = if let calleeFallback, case let .resize(_, choices) = calleeFallback,
                                            let inner = choices.first
        {
            inner
        } else {
            nil
        }
        context.sizeOverride = newSize
        guard let result = try generateRecursive(
            gen, with: inputValue, context: &context, fallbackTree: innerFallback
        ) else { return nil }
        return try runContinuation(
            result: result.0,
            calleeChoiceTree: .resize(newSize: newSize, choices: [result.1]),
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: transform (map / bind)

    @inline(__always)
    static func handleTransform<Output>(
        kind: TransformKind,
        inner: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Output, ChoiceTree)? {
        switch kind {
        case let .map(forward, _, _):
            guard let (innerValue, innerTree) = try generateRecursive(
                inner, with: inputValue, context: &context, fallbackTree: calleeFallback
            ) else { return nil }
            let result = try forward(innerValue)
            return try runContinuation(
                result: result, calleeChoiceTree: innerTree,
                continuation: continuation, inputValue: inputValue,
                context: &context, continuationFallback: continuationFallback
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

            guard let (innerValue, innerTree) = try generateRecursive(
                inner, with: inputValue, context: &context, fallbackTree: innerFallback
            ) else { return nil }

            let boundGen = try forward(innerValue)

            switch context.mode {
            case .exact:
                // No cursor suspension — bound values replay from prefix.
                // Track boundDepth for inner-reject vs bound-clamp at chooseBits.
                context.boundDepth += 1
                let boundResult = try generateRecursive(
                    boundGen, with: inputValue, context: &context,
                    fallbackTree: boundFallback
                )
                context.boundDepth -= 1
                guard let (boundValue, boundTree) = boundResult else { return nil }
                return try runContinuation(
                    result: boundValue,
                    calleeChoiceTree: .bind(inner: innerTree, bound: boundTree),
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case .guided:
                // Cursor suspension — bound content re-derived from fallback/PRNG.
                context.cursor.skipBindBound()
                context.cursor.suspendForBind()
                context.boundDepth += 1
                let boundResult = try generateRecursive(
                    boundGen, with: inputValue, context: &context,
                    fallbackTree: boundFallback
                )
                context.boundDepth -= 1
                context.cursor.resumeAfterBind()
                guard let (boundValue, boundTree) = boundResult else { return nil }
                return try runContinuation(
                    result: boundValue,
                    calleeChoiceTree: .bind(inner: innerTree, bound: boundTree),
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case .generate:
                // Pure generation — no prefix, no suspension.
                let boundResult = try generateRecursive(
                    boundGen, with: inputValue, context: &context, fallbackTree: nil
                )
                guard let (boundValue, boundTree) = boundResult else { return nil }
                return try runContinuation(
                    result: boundValue,
                    calleeChoiceTree: .bind(inner: innerTree, bound: boundTree),
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )
            }
        }
    }
}

// MARK: - Context

private extension ReductionMaterializer {
    struct Context: ~Copyable {
        var cursor: Cursor
        var prng: Xoshiro256
        var mode: InternalMode
        var size: UInt64
        var sizeOverride: UInt64?
        /// Tracks nesting depth inside reified bind's bound regions.
        /// Used in exact mode: `boundDepth > 0` → clamp; `boundDepth == 0` → reject.
        var boundDepth: Int = 0
        var maximizeBoundRegionIndices: Set<Int>?
        /// When `false`, pick sites skip non-selected branch materialization.
        /// Only `PromoteBranchesEncoder` needs full branch alternatives.
        var materializePicks: Bool = true
    }
}

// MARK: - Cursor

/// Position-based cursor that traverses the full ``ChoiceSequence`` including structural markers.
///
/// Group markers are transparently skipped. Sequence markers are handled explicitly.
/// Bind handling (skip/suspend/resume) is mode-dependent — callers decide whether to invoke them.
private extension ReductionMaterializer {
    struct Cursor: ~Copyable {
        private let entries: ChoiceSequence
        private(set) var position: Int = 0
        var exhausted: Bool = false

        /// When > 0, the cursor is inside a bind's bound subtree and should
        /// behave as exhausted so the materializer falls back to PRNG.
        private var bindSuspendDepth: Int = 0

        /// Stack of position limits for nested scopes (zip children).
        /// Max nesting depth ~3-4 in practice.
        private var scopeLimits = InlineBuffer<Int>(repeating: 0)

        /// Cached end position — updated on scope push/pop.
        private var effectiveEnd: Int

        static var empty: Cursor {
            Cursor(from: ChoiceSequence())
        }

        init(from sequence: consuming ChoiceSequence) {
            entries = sequence
            effectiveEnd = entries.count
        }

        // MARK: Scope management

        mutating func pushScope(limit: Int) {
            scopeLimits.append(limit)
            effectiveEnd = min(entries.count, limit)
        }

        mutating func popScope() {
            scopeLimits.removeLast()
            if let limit = scopeLimits.last {
                effectiveEnd = min(entries.count, limit)
            } else {
                effectiveEnd = entries.count
            }
        }

        // MARK: Skip transparent markers

        mutating func skipGroups() {
            while position < effectiveEnd {
                switch entries[position] {
                case .group, .bind, .just:
                    position &+= 1
                default:
                    return
                }
            }
        }

        // MARK: Bind support

        /// Advance past the bound content of a `.bind` node.
        mutating func skipBindBound() {
            var depth = 0
            while position < effectiveEnd {
                switch entries[position] {
                case .bind(true):
                    depth &+= 1
                    position += 1
                case .bind(false):
                    if depth == 0 {
                        position &+= 1
                        return
                    }
                    depth &-= 1
                    position &+= 1
                default:
                    position &+= 1
                }
            }
        }

        private(set) var bindEncounterCount: Int = 0

        mutating func suspendForBind() {
            bindSuspendDepth &+= 1
            bindEncounterCount += 1
        }

        mutating func resumeAfterBind() {
            bindSuspendDepth &-= 1
        }

        var isSuspended: Bool {
            bindSuspendDepth > 0
        }

        // MARK: Consume entries

        mutating func tryConsumeValue() -> ChoiceSequenceValue.Value? {
            guard exhausted == false, isSuspended == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            switch entries[position] {
            case let .value(v), let .reduced(v):
                position &+= 1
                return v
            default:
                exhausted = true
                return nil
            }
        }

        mutating func tryConsumeBranch() -> ChoiceSequenceValue.Branch? {
            guard exhausted == false, isSuspended == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            switch entries[position] {
            case let .branch(b):
                position &+= 1
                return b
            default:
                exhausted = true
                return nil
            }
        }

        // MARK: Sequence markers

        mutating func tryConsumeSequenceOpen() -> (elementCount: Int, isLengthExplicit: Bool)? {
            guard exhausted == false, isSuspended == false else { return nil }
            skipGroups()
            guard position < effectiveEnd else {
                exhausted = true
                return nil
            }
            guard case let .sequence(true, isLengthExplicit: isExplicit) = entries[position] else {
                exhausted = true
                return nil
            }
            position &+= 1

            guard let count = countTopLevelElements(from: position) else {
                exhausted = true
                return nil
            }
            return (elementCount: count, isLengthExplicit: isExplicit)
        }

        mutating func skipSequenceClose() {
            guard exhausted == false else { return }
            skipGroups()
            guard position < effectiveEnd else { return }
            if case .sequence(false, _) = entries[position] {
                position &+= 1
            }
        }

        private func countTopLevelElements(from startPos: Int) -> Int? {
            var pos = startPos
            var depth = 0
            var count = 0

            while pos < entries.count {
                switch entries[pos] {
                case .sequence(false, _) where depth == 0:
                    return count
                case .group(true), .bind(true), .sequence(true, _):
                    if depth == 0 { count &+= 1 }
                    depth &+= 1
                case .group(false), .bind(false), .sequence(false, _):
                    depth -= 1
                case .value, .reduced, .just:
                    if depth == 0 { count &+= 1 }
                case .branch:
                    break
                }
                pos &+= 1
            }
            return nil
        }
    }
}

// MARK: - InternalMode Equatable

extension ReductionMaterializer.InternalMode: Equatable {}
