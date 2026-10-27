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
        let calleeStart = context.flatCount
        guard let (result, tree) = try generateRecursive(
            nextGen, with: inputValue, context: &context, fallbackTree: calleeFallback
        ) else {
            return nil
        }
        return try runContinuation(
            result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
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
        let calleeStart = context.flatCount
        guard let (result, tree) = try generateRecursive(
            nextGen, with: wrappedValue, context: &context, fallbackTree: calleeFallback
        ) else {
            return nil
        }
        return try runContinuation(
            result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    // MARK: - chooseBits

    /// Reads a bit pattern from the cursor and converts it to a typed value via the ``TypeTag``.
    ///
    /// In exact mode the cursor must supply a value in range (or the handler rejects). In guided mode the handler falls through three tiers: cursor value, fallback tree, then PRNG. Bound values and non-explicit ranges are always clamped rather than rejected because their valid range may shift when inner values change. Float NaN and infinity bit patterns bypass clamping so problematic-value screening counterexamples remain reducible.
    @inline(__always)
    static func handleChooseBits(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        typeTagPayload: TypeTagPayload?,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        let resolved = try resolveChooseBits(
            min: min, max: max, tag: tag,
            isRangeExplicit: isRangeExplicit,
            scaling: scaling, typeTagPayload: typeTagPayload,
            context: &context, calleeFallback: calleeFallback
        )
        return try runContinuation(
            result: resolved.bits, calleeChoiceTree: resolved.tree, calleeStart: resolved.calleeStart,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }

    /// Resolves a `chooseBits` bit pattern for the current mode, emits its flat entry, and builds its tree node, without running the continuation. The sequence batch path calls this per element and converts the collected bits once.
    @inline(__always)
    static func resolveChooseBits(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        typeTagPayload: TypeTagPayload?,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil
    ) throws -> (bits: UInt64, tree: ChoiceTree, calleeStart: Int) {
        // A leaf's span excludes its continuation. Resume the prefix when the value is resolved, including in the fused and batched sequence paths. Preserve an enclosing pick's suspension when this leaf did not enter its own reseed scope.
        let reseeding = context.enterReseedIfTargeted()
        defer {
            if reseeding {
                context.cursor.suspended = false
            }
        }
        let randomBits: UInt64
        var reusedChoice: ChoiceValue?

        switch (context.mode, context.shouldUseMaximumDepthForScreening && tag == .depthControl) {
            case (.exact, _):
                guard let prefixValue = context.cursor.tryConsumeValue(expecting: tag) else {
                    throw RejectionError()
                }
                context.record(.prefix)
                let bp = prefixValue.choice.bitPattern64
                if context.boundDepth > 0 || isRangeExplicit == false {
                    // Bound value or non-explicit range: clamp to fresh range.
                    // Bound ranges may shift when inner values change.
                    // Non-explicit ranges (from size scaling) are context-dependent — the generator may derive a narrower range than the original, so clamping is safer than rejecting.
                    // Float NaN/infinity: pass through unclamped so the reducer can see non-finite problematic values.
                    randomBits = tag.clampBits(bp, min: min, max: max)
                } else {
                    // Explicit-range inner value: reject if out of range. Floating-point patterns pass through whatever their bits, as `clampBits` passes them through in guided mode: NaN and infinity keep problematic-value counterexamples reducible, and a prefix pattern below `min` that guided carried forward must replay exactly.
                    guard tag.isFloatingPoint || (bp >= min && bp <= max) else {
                        throw RejectionError()
                    }
                    // Validation proves integer bits are already in range, while floating-point bits deliberately pass through unchanged.
                    randomBits = bp
                }
                // Reuse original ChoiceValue when bits unchanged, avoiding tag.makeConvertible(bitPattern64:) reconstruction.
                if randomBits == bp {
                    reusedChoice = prefixValue.choice
                }

            case (.guided, true):
                // Screening forces the maximum feasible depth instead of consuming the prefix, so this walk cannot certify prefix-only replay.
                context.record(.screeningPolicy)
                let effectiveRange = scaling.map { scaling in
                    Gen.applyScaling(
                        min: min,
                        max: max,
                        tag: tag,
                        scaling: scaling,
                        size: Materializer.currentSize(&context)
                    )
                } ?? (min ... max)
                randomBits = effectiveRange.upperBound

            case (.guided, false):
                if let prefixValue = context.cursor.tryConsumeValue(expecting: tag) {
                    let bp = prefixValue.choice.bitPattern64
                    // Float NaN/infinity: pass through unclamped so the reducer can see non-finite problematic values.
                    randomBits = tag.clampBits(bp, min: min, max: max)
                    if randomBits == bp {
                        reusedChoice = prefixValue.choice
                    }
                    context.decodingReport?.record(tier: .exactCarryForward)
                } else if reseeding == false, let calleeFallback, case let .choice(value, _) = calleeFallback {
                    // Float NaN/infinity: pass through unclamped so the reducer can see non-finite problematic values.
                    randomBits = tag.clampBits(value.bitPattern64, min: min, max: max)
                    context.decodingReport?.record(tier: .fallbackTree)
                } else {
                    randomBits = context.prng.next(in: min ... max)
                    let tier: ResolutionTier = context.cursor.suspended ? .reseeded : .prng
                    context.decodingReport?.record(tier: tier)
                }

            case (.generate, _):
                // Fresh generation honors scaling; replay / guided / minimize operate on the declared range so they can reconstruct or target specific bit patterns without being re-narrowed.
                let effective = scaling.map { scaling in
                    Gen.applyScaling(
                        min: min,
                        max: max,
                        tag: tag,
                        scaling: scaling,
                        size: Materializer.currentSize(&context)
                    )
                } ?? (min ... max)
                // A pinned size never touches the PRNG, so the seed stream matches a raw getSize read.
                switch scaling?.isPinnedToSize {
                    case true?:
                        randomBits = effective.lowerBound
                    default:
                        randomBits = context.prng.next(in: effective)
                        context.record(.prng)
                }

            case (.minimize, _):
                let placeholder = ChoiceValue(min, tag: tag)
                randomBits = placeholder.reductionTarget(in: min ... max)
        }

        let calleeStart = context.flatCount
        if context.emitsFlat {
            context.flatOutput!.append(.value(.init(
                choice: reusedChoice ?? ChoiceValue(randomBits, tag: tag),
                validRange: min ... max,
                isRangeExplicit: isRangeExplicit
            )))
        }
        guard context.skipTree == false else {
            return (randomBits, .just, calleeStart)
        }
        let choice = reusedChoice ?? ChoiceValue(randomBits, tag: tag)
        let metadata = ChoiceMetadata(
            validRange: min ... max,
            isRangeExplicit: isRangeExplicit,
            typeTagPayload: typeTagPayload,
            isPinnedToSize: scaling?.isPinnedToSize == true
        )
        // Lifts repeatedly carry unchanged scalar leaves through new trees. Reuse their immutable boxes only after resolving the value and checking every piece of fresh metadata.
        if let calleeFallback,
           case let .choice(fallbackChoice, fallbackMetadata) = calleeFallback,
           fallbackChoice == choice,
           fallbackMetadata == metadata
        {
            return (randomBits, calleeFallback, calleeStart)
        }
        return (randomBits, .choice(choice, metadata), calleeStart)
    }

    // MARK: - resize

    /// Materializes the inner generator with ``Context/sizeOverride`` set to the given size, then restores the enclosing override before materializing the continuation.
    ///
    /// Every size read in the inner generator observes the same override. Nested resize operations restore this value when they finish, while operations composed after this resize observe the enclosing scope.
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
            else {
                return nil
            }
            return inner
        }
        let previousSizeOverride = context.sizeOverride
        let calleeStart = context.flatCount
        context.emitFlat(.group(true))
        let innerResult: (Any, ChoiceTree)?
        do {
            context.sizeOverride = newSize
            defer { context.sizeOverride = previousSizeOverride }
            context.cursor.skipGroupOpen()
            innerResult = try generateRecursive(
                gen,
                with: inputValue,
                context: &context,
                fallbackTree: innerFallback
            )
        }
        guard let innerResult else {
            return nil
        }
        context.emitFlat(.group(false))
        let calleeTree: ChoiceTree = context.skipTree
            ? .just
            : .resize(newSize: newSize, choices: [innerResult.1])
        return try runContinuation(
            result: innerResult.0,
            calleeChoiceTree: calleeTree,
            calleeStart: calleeStart,
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
        fallbackTree: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        // Transparent kinds (map, isomorph, metamorphic) add no callee tree node, so the fallback passes through whole; bind owns a callee node and splits the fallback.
        let calleeFallback: ChoiceTree?
        let continuationFallback: ChoiceTree?
        switch kind {
            case .bind:
                (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            case .map, .isomorph, .metamorphic:
                (calleeFallback, continuationFallback) = (fallbackTree, nil)
        }
        switch kind {
            case let .map(forward, _, _, _), let .isomorph(forward, _, _, _):
                let calleeStart = context.flatCount
                guard let (innerValue, innerTree) = try generateRecursive(
                    inner, with: inputValue, context: &context, fallbackTree: calleeFallback
                ) else {
                    return nil
                }
                let result = try forward(innerValue)
                return try runContinuation(
                    result: result, calleeChoiceTree: innerTree, calleeStart: calleeStart,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case let .bind(fingerprint, forward, _, _, _):
                let (innerFallback, boundFallback): (ChoiceTree?, ChoiceTree?) = switch calleeFallback {
                    case let .bind(_, fallbackInner, fallbackBound)?:
                        (fallbackInner, fallbackBound)
                    default:
                        (nil, nil)
                }

                context.cursor.skipBindOpen()
                let calleeStart = context.flatCount
                guard let (innerValue, innerTree) = try generateRecursive(
                    inner, with: inputValue, context: &context, fallbackTree: innerFallback
                ) else {
                    return nil
                }

                // The marker kind depends on the inner's shape, which is only known after the inner walk, so the open marker is retro-inserted before the inner's span (empty for a getSize inner). Matches flatten's getSize-bind group rewrite.
                let isGetSizeBind = innerTree.isGetSize
                if context.emitsFlat {
                    context.flatOutput!.insert(isGetSizeBind ? .group(true) : .bind(true), at: calleeStart)
                }

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
                        guard let (boundValue, boundTree) = boundResult else {
                            return nil
                        }
                        context.emitFlat(isGetSizeBind ? .group(false) : .bind(false))
                        let calleeTree: ChoiceTree = context.skipTree
                            ? .just
                            : .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
                        return try runContinuation(
                            result: boundValue,
                            calleeChoiceTree: calleeTree,
                            calleeStart: calleeStart,
                            continuation: continuation, inputValue: inputValue,
                            context: &context, continuationFallback: continuationFallback
                        )

                    case .guided:
                        // getSize-binds are structurally stable: getSize produces zero ChoiceSequence entries and returns a fixed value during reduction.
                        // Their markers are `.group` (not `.bind`), so skip cursor suspension — skipBindBound() would scan for `.bind` markers and corrupt the cursor.
                        //
                        // For non-getSize binds, suspend only when the inner value changed.
                        // When unchanged, the bound structure is identical and prefix entries are valid — the cursor stays active so encoder modifications to bound content are honored. Compare flattened ChoiceSequences (strips metadata, compares only values/branches/ markers).
                        // No bind suspension: the cursor reads entries as-is. Cross-depth promotions have structurally compatible bound content; stale entries from value changes are caught by the property check.
                        context.boundDepth += 1
                        let boundResult = try generateRecursive(
                            boundGen, with: inputValue, context: &context,
                            fallbackTree: boundFallback
                        )
                        context.boundDepth -= 1
                        guard let (boundValue, boundTree) = boundResult else {
                            return nil
                        }
                        context.emitFlat(isGetSizeBind ? .group(false) : .bind(false))
                        let calleeTree: ChoiceTree = context.skipTree
                            ? .just
                            : .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
                        return try runContinuation(
                            result: boundValue,
                            calleeChoiceTree: calleeTree,
                            calleeStart: calleeStart,
                            continuation: continuation, inputValue: inputValue,
                            context: &context, continuationFallback: continuationFallback
                        )

                    case .generate, .minimize:
                        // Pure generation — no prefix, no suspension.
                        let boundResult = try generateRecursive(
                            boundGen, with: inputValue, context: &context, fallbackTree: nil
                        )
                        guard let (boundValue, boundTree) = boundResult else {
                            return nil
                        }
                        context.emitFlat(isGetSizeBind ? .group(false) : .bind(false))
                        let calleeTree: ChoiceTree = context.skipTree
                            ? .just
                            : .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
                        return try runContinuation(
                            result: boundValue,
                            calleeChoiceTree: calleeTree,
                            calleeStart: calleeStart,
                            continuation: continuation, inputValue: inputValue,
                            context: &context, continuationFallback: continuationFallback
                        )
                }

            case let .metamorphic(transforms, _):
                // skipTree override: the metamorphic combinator produces independent copies via Interpreters.replay(inner, using: innerTree). Replay needs the real tree because the cursor has already advanced past the inner generator's choices — the tree is the only record of what choices were made. Without it, replay returns nil and every metamorphic generator fails materialization. The override is scoped to the inner generateRecursive call only; once innerTree is captured, skipTree is restored so runContinuation returns .just as its callee tree.
                // Flat emission is suspended for the same scope: the inner walk builds a real tree here, so its flattening is bulk-appended afterwards instead of emitted node by node.
                let calleeStart = context.flatCount
                let savedSkipTree = context.skipTree
                let savedSuspension = context.flatEmissionSuspended
                context.skipTree = false
                context.flatEmissionSuspended = true
                guard let (original, innerTree) = try generateRecursive(
                    inner, with: inputValue, context: &context, fallbackTree: calleeFallback
                ) else {
                    context.skipTree = savedSkipTree
                    context.flatEmissionSuspended = savedSuspension
                    return nil
                }
                context.skipTree = savedSkipTree
                context.flatEmissionSuspended = savedSuspension
                if context.emitsFlat {
                    context.flatOutput!.append(contentsOf: ChoiceSequence.flatten(innerTree))
                }
                var results: [Any] = [original]
                results.reserveCapacity(transforms.count + 1)
                for transform in transforms {
                    guard let copy = try Interpreters.replay(inner, using: innerTree) else {
                        return nil
                    }
                    try results.append(transform(copy))
                }
                let calleeTree: ChoiceTree = context.skipTree ? .just : innerTree
                return try runContinuation(
                    result: results as Any, calleeChoiceTree: calleeTree, calleeStart: calleeStart,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )
        }
    }

    // MARK: - filter / classify / unique

    /// Materializes through a filter site, re-checking the predicate against the materialized value and recording the observation.
    ///
    /// In guided mode a rejected predicate retries from the continuing seeded PRNG, bounded by ``__ExhaustRuntime/maxFilterRuns``, but only while the subtree is free: cursor spent at entry, nothing resolved from the fallback tree. A free value carries none of the row's identity, so redrawing corrupts neither the row nor the replay address; cursor- and fallback-fed values stay single-shot because rejection there means the addressed point is invalid. Inner generation failure never retries.
    ///
    /// A rejected attempt's flat emissions are truncated back to its entry index. Declining the retry under flat emission instead would make the flat walk reject inputs the tree walk accepts.
    @inline(__always)
    static func handleFilter(
        _ gen: AnyGenerator,
        fingerprint: UInt64,
        filterType: FilterType,
        predicate: (Any) -> Bool,
        sourceLocation: FilterSourceLocation,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree?,
        continuationFallback: ChoiceTree?
    ) throws -> (Any, ChoiceTree)? {
        let cursorSpentAtEntry = context.cursor.isSpent
        var attempts: UInt64 = 0
        while true {
            let calleeStart = context.flatCount
            let reportBeforeAttempt = context.decodingReport
            guard let (result, tree) = try generateRecursive(
                gen, with: inputValue, context: &context, fallbackTree: calleeFallback
            ) else {
                return nil
            }
            let passed = predicate(result)
            context.filterObservations[fingerprint, default: FilterObservation(sourceLocation: sourceLocation, filterType: filterType)]
                .recordAttempt(passed: passed)
            if passed {
                return try runContinuation(
                    result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )
            }
            attempts += 1
            // Checked per retry rather than on the element axis: a filter over a scalar inner advances no element index, so the generation deadline's sampled cadence never sees it, and nested filters compound the retry cap rather than sharing it.
            if context.deadlineNanoseconds > 0, MonotonicClock.nanoseconds() > context.deadlineNanoseconds {
                throw GeneratorError.generationDeadlineExceeded(
                    seconds: Double(SharedInterpreterHelpers.perValueGenerationBudgetNanoseconds) / 1_000_000_000
                )
            }
            // Without a decoding report, fallback consumption is unobservable; require no fallback at all.
            let consumedFallback = switch (reportBeforeAttempt, context.decodingReport) {
                case let (before?, after?):
                    after.fallbackResolutionCount > before.fallbackResolutionCount
                default:
                    calleeFallback != nil
            }
            guard context.mode == .guided,
                  cursorSpentAtEntry,
                  consumedFallback == false,
                  attempts < __ExhaustRuntime.maxFilterRuns
            else {
                return nil
            }
            // The failed attempt's tier counts would misstate the surviving value's provenance.
            context.restoreDecodingReport(reportBeforeAttempt)
            // Drop the failed attempt's emissions so the retry re-emits from the same index.
            context.flatOutput?.removeSubrange(calleeStart...)
        }
    }

    /// Materializes through a generation-only site (classify, unique) whose payload is irrelevant during materialization; the inner generator's choices are the only choices.
    @inline(__always)
    static func handlePassthrough(
        _ gen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree?,
        continuationFallback: ChoiceTree?
    ) throws -> (Any, ChoiceTree)? {
        let calleeStart = context.flatCount
        guard let (result, tree) = try generateRecursive(
            gen, with: inputValue, context: &context, fallbackTree: calleeFallback
        ) else {
            return nil
        }
        return try runContinuation(
            result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
            continuation: continuation, inputValue: inputValue,
            context: &context, continuationFallback: continuationFallback
        )
    }
}
