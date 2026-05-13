//
//  Materializer+Handlers.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Operation Handlers

extension Materializer {
    /// Materializes a ``ReflectiveOperation/contramap`` by recursing into the inner generator and threading the result through the continuation unchanged.
    @inline(__always)
    static func handleContramap(
        _ nextGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(
            nextGen, with: inputValue, context: &context, fallbackTree: calleeFallback
        ) else { return nil }
        return try runContinuation(
            result: result, calleeChoiceTree: tree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    /// Materializes a ``ReflectiveOperation/prune`` by unwrapping the prune input, then recursing into the inner generator.
    ///
    /// Returns nil if the prune predicate rejects the input, which propagates as a materialization failure to the caller.
    @inline(__always)
    static func handlePrune(
        _ nextGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
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

    // MARK: - chooseBits

    /// Reads a bit pattern from the cursor and converts it to a typed value via the ``TypeTag``.
    ///
    /// In exact mode the cursor must supply a value in range (or the handler rejects). In guided mode the handler falls through three tiers: cursor value, fallback tree, then PRNG. Bound values and non-explicit ranges are always clamped rather than rejected because their valid range may shift when inner values change. Float NaN and infinity bit patterns bypass clamping so boundary coverage counterexamples remain reducible.
    @inline(__always)
    static func handleChooseBits(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
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
                // Non-explicit ranges (from size scaling) are context-dependent — the generator may derive a narrower range than the original, so clamping is safer than rejecting.
                // Float NaN/infinity: pass through unclamped so the reducer can see non-finite boundary values.
                randomBits = tag.clampBits(bp, min: min, max: max)
            } else {
                // Explicit-range inner value: reject if out of range.
                // Float NaN/infinity: pass through so boundary coverage counterexamples are reducible.
                guard bp >= min, bp <= max || tag.isFloatingPoint else {
                    throw RejectionError()
                }
                randomBits = tag.clampBits(bp, min: min, max: max)
            }
            // Reuse original ChoiceValue when bits unchanged, avoiding tag.makeConvertible(bitPattern64:) reconstruction.
            if randomBits == bp {
                reusedChoice = prefixValue.choice
            }

        case .guided:
            if let prefixValue = context.cursor.tryConsumeValue() {
                let bp = prefixValue.choice.bitPattern64
                // Float NaN/infinity: pass through unclamped so the reducer can see non-finite boundary values.
                randomBits = tag.clampBits(bp, min: min, max: max)
                if randomBits == bp {
                    reusedChoice = prefixValue.choice
                }
                context.decodingReport?.record(tier: .exactCarryForward)
            } else if let calleeFallback, case let .choice(value, _) = calleeFallback {
                // Float NaN/infinity: pass through unclamped so the reducer can see non-finite boundary values.
                randomBits = tag.clampBits(value.bitPattern64, min: min, max: max)
                context.decodingReport?.record(tier: .fallbackTree)
            } else {
                randomBits = context.prng.next(in: min ... max)
                context.decodingReport?.record(tier: .prng)
            }

        case .generate:
            // Fresh generation honors scaling; replay / guided / minimize operate on the declared range so they can reconstruct or target specific bit patterns without being re-narrowed.
            let effective: ClosedRange<UInt64>
            if let scaling {
                let size = Materializer.consumeSize(&context)
                effective = Gen.applyScaling(
                    min: min, max: max, tag: tag, scaling: scaling, size: size
                )
            } else {
                effective = min ... max
            }
            randomBits = context.prng.next(in: effective)

        case .minimize:
            let placeholder = ChoiceValue(min, tag: tag)
            randomBits = placeholder.reductionTarget(in: min ... max)
        }

        let choiceTree: ChoiceTree = context.skipTree
            ? .just
            : .choice(
                reusedChoice ?? ChoiceValue(randomBits, tag: tag),
                .init(validRange: min ... max, isRangeExplicit: isRangeExplicit)
            )
        return try runContinuation(
            result: randomBits, calleeChoiceTree: choiceTree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: - pick (with materialized alternatives)

    /// Selects a branch by reading the branch index from the cursor, then materializes the selected branch's generator.
    ///
    /// In exact mode the cursor must supply a valid branch index or the handler rejects. In guided mode the handler tries the cursor, then the fallback tree's selected branch, then weighted random selection. When ``Context/materializePicks`` is set, non-selected branches are also materialized in minimize mode to populate the ``ChoiceTree`` with shortlex-simplest content for coverage analysis.
    @inline(__always)
    static func handlePick(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        branchCount: UInt64,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        // Always consume a jump seed from the PRNG stream (VACTI pattern).
        let jumpSeed = context.prng.next()

        // Extract fallback branch info. For Gen.recursive, the pick site is wrapped in a bind — unwrap to reach the group with branch alternatives.
        let fbBranchId: UInt64?
        let branchChoiceTree: ChoiceTree?
        let effectiveFallback: ChoiceTree? = switch calleeFallback {
        case let .bind(_, _, bound): bound
        default: calleeFallback
        }
        if let effectiveFallback,
           case let .group(children, _) = effectiveFallback,
           case let .branch(b) = children.first(where: \.isSelected), b.isSelected
        {
            fbBranchId = b.id
            branchChoiceTree = b.choice
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
            let exactIndex = Int(prefixBranch.id)
            selectedChoice = exactIndex < choices.count ? choices[exactIndex] : nil

        case .guided:
            if let prefixBranch = context.cursor.tryConsumeBranch() {
                let guidedIndex = Int(prefixBranch.id)
                selectedChoice = guidedIndex < choices.count ? choices[guidedIndex] : nil
            } else if let fbBranchId {
                let fallbackIndex = Int(fbBranchId)
                selectedChoice = fallbackIndex < choices.count ? choices[fallbackIndex] : nil
            } else {
                selectedChoice = WeightedPickSelection.draw(from: choices, using: &context.prng)
            }

        case .generate:
            selectedChoice = WeightedPickSelection.draw(from: choices, using: &context.prng)

        case .minimize:
            selectedChoice = choices.first
        }

        guard let selectedChoice else { return nil }

        // Decompose branch choice tree for selected branch fallback.
        let (branchBodyFallback, branchContFallback) = decomposeNonGroupFallback(
            branchChoiceTree
        )

        if context.skipTree {
            guard let (result, _) = try generateRecursive(
                selectedChoice.generator, with: inputValue, context: &context,
                fallbackTree: branchBodyFallback
            ) else { return nil }
            return try runContinuation(
                result: result, calleeChoiceTree: .just,
                continuation: continuation, inputValue: inputValue,
                context: &context,
                continuationFallback: branchContFallback ?? continuationFallback
            )
        }

        // Execute selected branch; optionally materialize non-selected branches.
        var branches = [ChoiceTree]()
        branches.reserveCapacity(context.materializePicks ? choices.count : 1)
        var finalValue: Any?
        let fingerprint = choices[0].fingerprint

        if context.materializePicks {
            let selectedIndex = Int(selectedChoice.id)

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
                    branches.append(.branch(
                        fingerprint: fingerprint, weight: choice.weight,
                        id: choice.id, branchCount: branchCount, choice: contTree,
                        isSelected: true
                    ))
                } else {
                    // Non-selected branch: minimize to produce the shortlex-simplest content. Values use reductionTarget (semantic zero when in range), nested picks select the first branch, and sequence lengths minimize.
                    // The PRNG is only a fallback for operations without minimize-specific handling (filters, recursive unfolds).
                    var branchContext = Context(
                        cursor: Cursor.empty,
                        prng: Xoshiro256(seed: jumpSeed),
                        mode: .minimize,
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
                            fingerprint: fingerprint, weight: choice.weight,
                            id: choice.id, branchCount: branchCount, choice: contTree
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
            branches.append(.branch(
                fingerprint: fingerprint, weight: selectedChoice.weight,
                id: selectedChoice.id, branchCount: branchCount, choice: contTree,
                isSelected: true
            ))
        }

        guard let value = finalValue else { return nil }
        return (value, .group(branches))
    }

    // MARK: - sequence

    /// Materializes a variable-length sequence by resolving the length, then materializing each element in order.
    ///
    /// Length resolution is mode-dependent: exact mode trusts the cursor's element count, guided mode clamps cursor or fallback lengths to the generator's valid range, and generate mode runs the length generator fresh. After all elements are materialized the cursor's sequence-close marker is consumed so the caller's cursor position is consistent.
    @inline(__always)
    static func handleSequence(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        let length: UInt64
        let lengthMeta: ChoiceMetadata
        var elementFallbacks: [ChoiceTree]?

        var fallbackLength: UInt64?

        if let calleeFallback, case let .sequence(fbLength, fbElements, _) = calleeFallback {
            elementFallbacks = fbElements
            fallbackLength = fbLength
        }

        if let seqInfo = context.cursor.tryConsumeSequenceOpen() {
            if seqInfo.isLengthExplicit, context.mode == .exact {
                // Exact mode + explicit-length: the prefix is authoritative.
                // The length value is not stored in the flattened sequence, so we can't consume it from the cursor. Use the prefix element count.
                length = UInt64(seqInfo.elementCount)
                // Fast path: extract metadata directly from chooseBits length generators (the common case, for example `array(length: 0...10)`), avoiding a full generateRecursive + runContinuation round-trip.
                lengthMeta = try extractLengthMetadata(lengthGen)
            } else if seqInfo.isLengthExplicit {
                // Guided/generate mode + explicit-length: use the prefix element count, clamped to the generator's valid range. For fixed-length generators (for example `exactly: 2`, range 2...2) this produces 2 regardless of prefix. For variable-length generators (for example
                // `length: 0...10`) this preserves the prefix count. Analogous to the fallback-length clamping at the cursor-suspended path below.
                let prefixCount = UInt64(seqInfo.elementCount)
                lengthMeta = try extractLengthMetadata(lengthGen)
                if let freshRange = lengthMeta.validRange {
                    let clamped = Swift.max(prefixCount, freshRange.lowerBound)
                    length = Swift.min(clamped, freshRange.upperBound)
                } else {
                    length = prefixCount
                }
            } else {
                // Variable-length (non-explicit): derive from prefix element count.
                length = UInt64(seqInfo.elementCount)
                lengthMeta = ChoiceMetadata(validRange: nil, isRangeExplicit: false)
            }
        } else if context.mode == .exact {
            // Exact mode: prefix exhausted or structural mismatch at sequence site.
            throw RejectionError()
        } else if let fbLen = fallbackLength {
            // Cursor exhausted in guided mode. Use the fallback tree's stored length, clamped to the generator's valid range.
            let resolvedLen = fbLen
            lengthMeta = try extractLengthMetadata(lengthGen)
            if let freshRange = lengthMeta.validRange {
                let clamped = Swift.max(resolvedLen, freshRange.lowerBound)
                length = Swift.min(clamped, freshRange.upperBound)
            } else {
                length = resolvedLen
            }
        } else {
            let erasedLengthGen = lengthGen.erase()
            guard let (freshLength, _) = try generateRecursive(
                erasedLengthGen, with: inputValue, context: &context
            ) else { return nil }
            // swiftlint:disable:next force_cast
            length = freshLength as! UInt64
            lengthMeta = try extractLengthMetadata(lengthGen)
        }

        var results: [Any] = []
        results.reserveCapacity(Int(length))
        var elements: [ChoiceTree] = []
        if context.skipTree == false {
            elements.reserveCapacity(Int(length))
        }

        var elementIndex = 0
        var remaining = length
        while remaining > 0 {
            let elFB: ChoiceTree? = elementFallbacks.flatMap { fbs in
                elementIndex < fbs.count ? fbs[elementIndex] : nil
            }
            guard let (result, element) = try generateRecursive(
                elementGen, with: inputValue, context: &context, fallbackTree: elFB
            ) else { return nil }
            results.append(result)
            if context.skipTree == false {
                elements.append(element)
            }
            elementIndex += 1
            remaining -= 1
        }

        context.cursor.skipSequenceClose()

        let choiceTree: ChoiceTree = context.skipTree
            ? .just
            : .sequence(length: length, elements: elements, lengthMeta)

        if let (result, _) = try runContinuation(
            result: results, calleeChoiceTree: choiceTree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        ) {
            return (result, choiceTree)
        }
        return nil
    }

    // MARK: - zip

    /// Materializes each component of a zip in declaration order, collecting results into an array for the continuation.
    ///
    /// When a fallback tree is available, each child is scoped to its flattened entry count so guided-mode cursor reads cannot bleed into sibling components. Scope limits are computed arithmetically from the cursor's position at the zip's group-open marker to avoid drift from transparent group markers consumed by ``Cursor/skipGroups()``.
    @inline(__always)
    static func handleZip(
        _ generators: ContiguousArray<AnyGenerator>,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        let fallbackChildren: [ChoiceTree]? = calleeFallback.flatMap { fallback -> [ChoiceTree]? in
            guard case let .group(children, _) = fallback,
                  children.count == generators.count
            else { return nil }
            return children
        }

        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees: [ChoiceTree] = []
        if context.skipTree == false {
            choiceTrees.reserveCapacity(generators.count)
        }

        let canScope = fallbackChildren != nil

        // Scope limits are computed arithmetically from the cursor's current position (which sits at the zip's group-open marker). Each child's scope starts at basePosition + 1 (past the group-open) plus the cumulative flattenedEntryCount of preceding children. This avoids the cursor-position-based calculation that drifted when skipGroups()
        // consumed a child's leading group(true) markers.
        var childScopeStart = context.cursor.position + 1 // past the zip group open

        // Advance the cursor past transparent markers so it is ready for the first child's consume calls (tryConsumeBranch / tryConsumeValue).
        if canScope { context.cursor.skipGroups() }

        // while-loop: avoiding zip/IteratorProtocol overhead in debug builds.
        var zipIndex = 0
        while zipIndex < generators.count {
            let gen = generators[zipIndex]
            let fb: ChoiceTree? = fallbackChildren?[zipIndex]
            if canScope, let fb {
                context.cursor.pushScope(limit: childScopeStart + fb.flattenedEntryCount)
            }
            guard let (result, tree) = try generateRecursive(
                gen, with: inputValue, context: &context, fallbackTree: fb
            ) else {
                if canScope, fb != nil { context.cursor.popScope() }
                return nil
            }
            if canScope, fb != nil { context.cursor.popScope() }
            if canScope { context.cursor.skipGroupCloses() }
            if let fb { childScopeStart += fb.flattenedEntryCount }
            results.append(result)
            if context.skipTree == false {
                choiceTrees.append(tree)
            }
            zipIndex += 1
        }
        let calleeTree: ChoiceTree = context.skipTree ? .just : .group(choiceTrees)
        return try runContinuation(
            result: results, calleeChoiceTree: calleeTree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: - resize

    /// Materializes the inner generator with ``Context/sizeOverride`` set to the given size, then clears the override.
    ///
    /// The override is cleared defensively after the inner call in case a downstream ``ReflectiveOperation/getSize`` was missing, which would leave a stale override for subsequent operations.
    @inline(__always)
    static func handleResize(
        newSize: UInt64,
        gen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        let innerFallback: ChoiceTree? = calleeFallback.flatMap { fallback -> ChoiceTree? in
            guard case let .resize(_, choices) = fallback,
                  let inner = choices.first
            else { return nil }
            return inner
        }
        context.sizeOverride = newSize
        guard let result = try generateRecursive(
            gen, with: inputValue, context: &context, fallbackTree: innerFallback
        ) else { return nil }
        // Defensive clear — consumed by getSize, but guard against missing getSize.
        context.sizeOverride = nil
        let calleeTree: ChoiceTree = context.skipTree
            ? .just
            : .resize(newSize: newSize, choices: [result.1])
        return try runContinuation(
            result: result.0,
            calleeChoiceTree: calleeTree,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: - transform (map / bind)

    /// Materializes a reified ``TransformKind`` (map, bind, or metamorphic) by recursing into the inner generator and applying the forward transform.
    ///
    /// For map transforms the forward closure is applied directly to the inner result. For bind transforms the forward closure produces a bound generator that is also materialized; ``Context/boundDepth`` is incremented so downstream ``handleChooseBits`` knows to clamp rather than reject out-of-range values. For metamorphic transforms, ``Context/skipTree`` is temporarily disabled because ``Interpreters/replay(_:using:)`` needs the real inner tree to produce independent copies.
    @inline(__always)
    static func handleTransform(
        kind: TransformKind,
        inner: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
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

        case let .bind(fingerprint, forward, _, _, _):
            let innerFallback: ChoiceTree?
            let boundFallback: ChoiceTree?
            if let calleeFallback, case let .bind(_, iFB, bFB) = calleeFallback {
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
                let calleeTree: ChoiceTree = context.skipTree
                    ? .just
                    : .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
                return try runContinuation(
                    result: boundValue,
                    calleeChoiceTree: calleeTree,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case .guided:
                // getSize-binds are structurally stable: getSize produces zero ChoiceSequence entries and returns a fixed value during reduction.
                // Their markers are `.group` (not `.bind`), so skip cursor suspension — skipBindBound() would scan for `.bind` markers and corrupt the cursor.
                //
                // For non-getSize binds, suspend only when the inner value changed.
                // When unchanged, the bound structure is identical and prefix entries are valid — the cursor stays active so encoder modifications to bound content are honoured. Compare flattened ChoiceSequences (strips metadata, compares only values/branches/ markers).
                // No bind suspension: the cursor reads entries as-is. Cross-depth promotions have structurally compatible bound content; stale entries from value changes are caught by the property check.
                context.boundDepth += 1
                let boundResult = try generateRecursive(
                    boundGen, with: inputValue, context: &context,
                    fallbackTree: boundFallback
                )
                context.boundDepth -= 1
                guard let (boundValue, boundTree) = boundResult else { return nil }
                let calleeTree: ChoiceTree = context.skipTree
                    ? .just
                    : .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
                return try runContinuation(
                    result: boundValue,
                    calleeChoiceTree: calleeTree,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case .generate, .minimize:
                // Pure generation — no prefix, no suspension.
                let boundResult = try generateRecursive(
                    boundGen, with: inputValue, context: &context, fallbackTree: nil
                )
                guard let (boundValue, boundTree) = boundResult else { return nil }
                let calleeTree: ChoiceTree = context.skipTree
                    ? .just
                    : .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
                return try runContinuation(
                    result: boundValue,
                    calleeChoiceTree: calleeTree,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )
            }

        case let .metamorphic(transforms, _):
            // skipTree override: the metamorphic combinator produces independent copies via Interpreters.replay(inner, using: innerTree). Replay needs the real tree because the cursor has already advanced past the inner generator's choices — the tree is the only record of what choices were made. Without it, replay returns nil and every metamorphic generator fails materialisation. The override is scoped to the inner generateRecursive call only; once innerTree is captured, skipTree is restored so runContinuation returns .just as its callee tree.
            let savedSkipTree = context.skipTree
            context.skipTree = false
            guard let (original, innerTree) = try generateRecursive(
                inner, with: inputValue, context: &context, fallbackTree: calleeFallback
            ) else {
                context.skipTree = savedSkipTree
                return nil
            }
            context.skipTree = savedSkipTree
            var results: [Any] = [original]
            results.reserveCapacity(transforms.count + 1)
            for transform in transforms {
                guard let copy = try Interpreters.replay(inner, using: innerTree) else { return nil }
                try results.append(transform(copy))
            }
            let calleeTree: ChoiceTree = context.skipTree ? .just : innerTree
            return try runContinuation(
                result: results as Any, calleeChoiceTree: calleeTree,
                continuation: continuation, inputValue: inputValue,
                context: &context, continuationFallback: continuationFallback
            )
        }
    }

    /// Extracts ``ChoiceMetadata`` (valid range and explicitness) from a sequence's length generator without running a full materialization round-trip.
    ///
    /// Handles two common shapes: a bare ``ReflectiveOperation/chooseBits`` and a ``ReflectiveOperation/getSize``-wrapped chooseBits. Returns empty metadata when the generator has an unrecognized shape, which causes the caller to skip range clamping.
    private static func extractLengthMetadata(
        _ lengthGen: Generator<UInt64>
    ) throws -> ChoiceMetadata {
        if case let .impure(.chooseBits(min, max, _, isRangeExplicit, _), _) = lengthGen {
            return ChoiceMetadata(validRange: min ... max, isRangeExplicit: isRangeExplicit)
        }
        if case let .impure(.getSize, sizeContinuation) = lengthGen,
           case let .impure(.chooseBits(min, max, _, isRangeExplicit, _), _) = try sizeContinuation(100 as Any)
        {
            return ChoiceMetadata(validRange: min ... max, isRangeExplicit: isRangeExplicit)
        }
        return ChoiceMetadata(validRange: nil, isRangeExplicit: false)
    }
}
