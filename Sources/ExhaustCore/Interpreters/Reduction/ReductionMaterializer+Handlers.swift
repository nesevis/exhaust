//
//  ReductionMaterializer+Handlers.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// swiftlint:disable function_parameter_count

// MARK: - Operation Handlers

extension ReductionMaterializer {
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
                context.decodingReport?.record(tier: .exactCarryForward)
            } else if let indices = context.maximizeBoundRegionIndices,
                      context.cursor.isSuspended,
                      indices.contains(context.cursor.bindEncounterCount - 1)
            {
                randomBits = max
                context.decodingReport?.record(tier: .fallbackTree)
            } else if let calleeFallback, case let .choice(value, _) = calleeFallback {
                randomBits = Swift.min(Swift.max(value.bitPattern64, min), max)
                context.decodingReport?.record(tier: .fallbackTree)
            } else {
                randomBits = context.prng.next(in: min ... max)
                context.decodingReport?.record(tier: .prng)
            }

        case .generate:
            randomBits = context.prng.next(in: min ... max)

        case .minimize:
            let placeholder = ChoiceValue(min, tag: tag)
            randomBits = placeholder.reductionTarget(in: min ... max)
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

        // Extract fallback branch info. For Gen.recursive, the pick site is wrapped
        // in a bind — unwrap to reach the group with branch alternatives.
        let fbBranchId: UInt64?
        let branchChoiceTree: ChoiceTree?
        let effectiveFallback: ChoiceTree?
        if case let .bind(_, bound) = calleeFallback {
            effectiveFallback = bound
        } else {
            effectiveFallback = calleeFallback
        }
        if let effectiveFallback,
           case let .group(children, _) = effectiveFallback,
           let selected = children.first(where: \.isSelected)?.unwrapped,
           case let .branch(_, _, id, _, choice) = selected
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

        case .minimize:
            selectedChoice = choices.first
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
        let augmentedSiteID = choices[0].siteID &+ context.pickDepth
        let savedPickDepth = context.pickDepth
        context.pickDepth += 1

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
                        siteID: augmentedSiteID, weight: choice.weight,
                        id: choice.id, branchIDs: branchIDs, choice: contTree
                    )))
                } else {
                    // Non-selected branch: minimize to produce the shortlex-simplest
                    // content. Values use reductionTarget (semantic zero when in range),
                    // nested picks select the first branch, and sequence lengths minimize.
                    // The PRNG is only a fallback for operations without minimize-specific
                    // handling (filters, recursive unfolds).
                    var branchContext = Context(
                        cursor: Cursor.empty,
                        prng: Xoshiro256(seed: jumpSeed),
                        mode: .minimize,
                        size: context.size,
                        pickDepth: context.pickDepth
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
                            siteID: augmentedSiteID, weight: choice.weight,
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
                siteID: augmentedSiteID, weight: selectedChoice.weight,
                id: selectedChoice.id, branchIDs: branchIDs, choice: contTree
            )))
        }

        context.pickDepth = savedPickDepth

        guard let value = finalValue else { return nil }
        return (value, .group(branches))
    }

    // MARK: sequence

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

        var fallbackLength: UInt64?

        if let calleeFallback, case let .sequence(fbLength, fbElements, _) = calleeFallback {
            elementFallbacks = fbElements
            fallbackLength = fbLength
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
                    lengthMeta = ChoiceMetadata(
                        validRange: min ... max,
                        isRangeExplicit: isRangeExplicit
                    )
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
                // Guided/generate mode + explicit-length: use the prefix element
                // count, clamped to the generator's valid range. For fixed-length
                // generators (e.g. `exactly: 2`, range 2...2) this produces 2
                // regardless of prefix. For variable-length generators (e.g.
                // `length: 0...10`) this preserves the prefix count. Analogous to
                // the fallback-length clamping at the cursor-suspended path below.
                let prefixCount = UInt64(seqInfo.elementCount)
                let savedMode = context.mode
                context.mode = .generate
                guard let (_, lengthTree) = try generateRecursive(
                    lengthGen, with: inputValue, context: &context
                ) else {
                    context.mode = savedMode
                    return nil
                }
                context.mode = savedMode
                if let freshRange = lengthTree.metadata.validRange {
                    let clamped = Swift.max(prefixCount, freshRange.lowerBound)
                    length = Swift.min(clamped, freshRange.upperBound)
                } else {
                    length = prefixCount
                }
                lengthMeta = lengthTree.metadata
            } else {
                // Variable-length (non-explicit): derive from prefix element count.
                length = UInt64(seqInfo.elementCount)
                lengthMeta = ChoiceMetadata(validRange: nil, isRangeExplicit: false)
            }
        } else if context.mode == .exact {
            // Exact mode: prefix exhausted or structural mismatch at sequence site.
            throw RejectionError()
        } else if let fbLen = fallbackLength {
            // Cursor suspended (inside bind's bound content in guided mode). Prefer the
            // prefix-derived element count captured before skipBindBound() discarded the
            // sequence markers over the fallback tree's stored length. This keeps content
            // that earlier reduction phases deleted from being regenerated.
            // See docs/Guided Decoder Redistribution Gap.md.
            let resolvedLen = context.capturedBindBoundSequenceLength.map { UInt64($0) } ?? fbLen
            context.capturedBindBoundSequenceLength = nil
            let savedMode = context.mode
            context.mode = .generate
            guard let (_, lengthTree) = try generateRecursive(
                lengthGen, with: inputValue, context: &context
            ) else {
                context.mode = savedMode
                return nil
            }
            context.mode = savedMode
            if let freshRange = lengthTree.metadata.validRange {
                let clamped = Swift.max(resolvedLen, freshRange.lowerBound)
                length = Swift.min(clamped, freshRange.upperBound)
            } else {
                length = resolvedLen
            }
            lengthMeta = lengthTree.metadata
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
        let fallbackChildren: [ChoiceTree]? = if let calleeFallback,
                                                 case let .group(children, _) = calleeFallback,
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

        // Scope limits are computed arithmetically from the cursor's current
        // position (which sits at the zip's group-open marker). Each child's
        // scope starts at basePosition + 1 (past the group-open) plus the
        // cumulative flattenedEntryCount of preceding children. This avoids
        // the cursor-position-based calculation that drifted when skipGroups()
        // consumed a child's leading group(true) markers.
        var childScopeStart = context.cursor.position + 1 // past the zip group open

        // Advance the cursor past transparent markers so it is ready for the
        // first child's consume calls (tryConsumeBranch / tryConsumeValue).
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
        let innerFallback: ChoiceTree? = if let calleeFallback,
                                            case let .resize(_, choices) = calleeFallback,
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
        // Defensive clear — consumed by getSize, but guard
        // against missing getSize.
        context.sizeOverride = nil
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
                // getSize-binds are structurally stable: getSize produces zero
                // ChoiceSequence entries and returns a fixed value during reduction.
                // Their markers are `.group` (not `.bind`), so skip cursor
                // suspension — skipBindBound() would scan for `.bind` markers
                // and corrupt the cursor.
                let isGetSizeBind = innerTree.isGetSize
                if isGetSizeBind == false {
                    let peeked = context.cursor.peekSequenceLength()
                    context.capturedBindBoundSequenceLength = peeked
                    context.cursor.skipBindBound()
                    context.cursor.suspendForBind()
                }
                context.boundDepth += 1
                let boundResult = try generateRecursive(
                    boundGen, with: inputValue, context: &context,
                    fallbackTree: boundFallback
                )
                context.boundDepth -= 1
                if isGetSizeBind == false {
                    context.cursor.resumeAfterBind()
                }
                guard let (boundValue, boundTree) = boundResult else { return nil }
                return try runContinuation(
                    result: boundValue,
                    calleeChoiceTree: .bind(inner: innerTree, bound: boundTree),
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case .generate, .minimize:
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
