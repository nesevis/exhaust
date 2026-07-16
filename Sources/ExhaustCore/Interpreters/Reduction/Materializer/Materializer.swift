//
//  Materializer.swift
//  Exhaust
//

/// Replays a candidate ``ChoiceSequence`` through a generator to produce a fresh ``ChoiceTree`` with current metadata.
///
/// Two modes:
/// - **Exact**: every value comes from the prefix. Out-of-range values reject the candidate.
/// - **Guided**: three-tier resolution — prefix first, then fallback tree, then PRNG. Values that fit the new domain are carried forward unchanged; values that don't fall back to the next tier.
///
/// Always materializes all branch alternatives at pick sites so structural encoders can see inactive candidates. The result omits ``ChoiceSequence`` — the caller flattens `result.tree` to get a sequence with fresh metadata.
package enum Materializer {
    /// Returns the active generation size for a materialization call, preferring the innermost `.resize` override before the persistent `context.size` baseline.
    @inline(__always)
    static func currentSize(_ context: inout Context) -> UInt64 {
        if let override = context.sizeOverride {
            return override
        }
        return context.size
    }

    /// Controls how values are resolved at each choice point.
    public enum Mode {
        /// Replay all values from prefix. Reject out-of-range inner values, clamp bound values.
        /// No cursor suspension for binds.
        case exact

        /// Three-tiered resolution: prefix → fallback → PRNG. Clamp to range. Cursor suspension at bind sites.
        case guided(seed: UInt64, fallbackTree: ChoiceTree?,
                    maximizeBoundRegionIndices: Set<Int>? = nil)
    }

    /// Result of a reduction materialization attempt.
    ///
    /// All cases carry an optional ``DecodingReport`` containing resolution tier counts and per-fingerprint filter observations from the materialization pass.
    public enum Result<Output> {
        /// Materialization succeeded with a value and fresh tree.
        case success(value: Output, tree: ChoiceTree, decodingReport: DecodingReport?)
        /// Exact mode: out-of-range or structural mismatch — candidate is invalid.
        case rejected(decodingReport: DecodingReport?)
        /// Generation or user-supplied operation failure that is not an invalid exact candidate.
        case failed(decodingReport: DecodingReport?)
    }

    /// Materialize a generator using the given prefix and mode.
    ///
    /// - Parameters:
    ///   - gen: The generator to materialize.
    ///   - prefix: The choice sequence to replay from.
    ///   - mode: How to resolve values at each choice point.
    /// - Returns: A `Result` containing the output value and fresh tree on success.
    public static func materialize<Output>(
        _ gen: Generator<Output>,
        prefix: consuming ChoiceSequence,
        mode: Mode,
        fallbackTree: ChoiceTree? = nil,
        materializePicks: Bool = false,
        precomputedSeed: UInt64? = nil
    ) -> Result<Output> {
        // Generic public entry point — erases the input generator and casts the result back to ``Output`` at the boundary, delegating to the non-generic ``materializeAny``. Hot-path callers (schedulers, decoders) should hold an already-erased ``AnyGenerator`` and call ``materializeAny`` directly to avoid the per-call erasure cost.
        let anyResult = materializeAny(
            gen.erase(),
            prefix: consume prefix,
            mode: mode,
            fallbackTree: fallbackTree,
            materializePicks: materializePicks,
            precomputedSeed: precomputedSeed
        )
        switch anyResult {
            case let .success(value, tree, report):
                // swiftlint:disable:next force_cast
                return .success(value: value as! Output, tree: tree, decodingReport: report)
            case let .rejected(report):
                return .rejected(decodingReport: report)
            case let .failed(report):
                return .failed(decodingReport: report)
        }
    }

    /// Materializes a value from an already-erased generator and a choice-sequence prefix.
    ///
    /// Accepts ``AnyGenerator`` to avoid the per-`Output`-type metadata cache lookups that a generic `<Output>` parameter would impose inside ``generateRecursive``. Callers that hold a typed ``Generator`` should use the generic ``materialize(_:prefix:mode:fallbackTree:materializePicks:precomputedSeed:)`` overload, which erases at the boundary and forwards here.
    ///
    /// - Parameter collectDecodingReport: When `false`, the result carries a `nil` ``DecodingReport`` and per-coordinate tier recording is skipped. Callers that never read the report (screening rows) opt out to avoid the per-coordinate bookkeeping.
    public static func materializeAny(
        _ gen: AnyGenerator,
        prefix: consuming ChoiceSequence,
        mode: Mode,
        fallbackTree: ChoiceTree? = nil,
        materializePicks: Bool = false,
        precomputedSeed: UInt64? = nil,
        skipTree: Bool = false,
        collectDecodingReport: Bool = true
    ) -> Result<Any> {
        let seed: UInt64
        let resolvedFallbackTree: ChoiceTree?
        let maximizeBoundRegionIndices: Set<Int>?

        switch mode {
            case .exact:
                // The seed only feeds context.prng. In exact mode the PRNG is consulted nowhere except the pick handler's jump-seed draw, whose value is discarded unless materializePicks routes it into non-selected branch contexts. Without materializePicks the O(n) prefix hash buys nothing and a constant seed is byte-identical.
                seed = precomputedSeed ?? (materializePicks ? ZobristHash.hash(of: prefix) : 0)
                // Exact mode never reads the fallback tree at value sites (all values come from the prefix), but handleZip still consults it for per-child fallback threading and for secondary scope limits when the prefix does not parse at a zip site. Scope rejection of structurally misaligned candidates before the property runs is load-bearing: dropping scoping nearly doubles materializations on batch cross-sequence removal (Bound25).
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
            // Size 1 (scaledSize(forRun: 0)) would produce tiny ranges that reject or clamp valid values from larger-size generations.
            size: 100,
            maximizeBoundRegionIndices: maximizeBoundRegionIndices,
            materializePicks: materializePicks,
            skipTree: skipTree,
            decodingReport: collectDecodingReport ? DecodingReport() : nil
        )

        do {
            guard let (value, tree) = try generateRecursive(
                gen, with: (), context: &context, fallbackTree: resolvedFallbackTree
            ) else {
                var report = context.decodingReport
                report?.filterObservations = context.filterObservations
                switch mode {
                    case .exact: return .rejected(decodingReport: report)
                    case .guided: return .failed(decodingReport: report)
                }
            }
            var report = context.decodingReport
            report?.filterObservations = context.filterObservations
            return .success(value: value, tree: tree, decodingReport: report)
        } catch is RejectionError {
            var report = context.decodingReport
            report?.filterObservations = context.filterObservations
            return .rejected(decodingReport: report)
        } catch {
            var report = context.decodingReport
            report?.filterObservations = context.filterObservations
            return .failed(decodingReport: report)
        }
    }
}

// MARK: - Flat Emission

package extension Materializer {
    /// Result of a flat-emission materialization: the value and the flattened sequence, with no `ChoiceTree`.
    enum FlatResult {
        /// Materialization succeeded with a value and the sequence the equivalent tree would flatten to.
        case success(value: Any, sequence: ChoiceSequence, decodingReport: DecodingReport?)
        /// Exact mode: out-of-range or structural mismatch; the candidate is invalid.
        case rejected(decodingReport: DecodingReport?)
        /// Generation or user-supplied operation failure that is not an invalid exact candidate.
        case failed(decodingReport: DecodingReport?)
    }

    /// Materializes a value from an already-erased generator, emitting the flattened `ChoiceSequence` directly during the walk instead of building a `ChoiceTree`.
    ///
    /// The returned sequence is entry-for-entry identical to `ChoiceSequence.flatten` of the tree that `materializeAny` would produce for the same inputs, and cursor and PRNG consumption match exactly, so a later tree-building rematerialization with the same inputs reproduces this result. Use this when the caller needs the sequence (deduplication, hashing, corpus identity) but not the tree; rebuild the tree on demand with `materializeAny`.
    ///
    /// Non-selected pick branches are never emitted (flatten only includes the selected branch), so there is no `materializePicks` parameter.
    static func materializeAnyFlat(
        _ gen: AnyGenerator,
        prefix: consuming ChoiceSequence,
        mode: Mode,
        fallbackTree: ChoiceTree? = nil,
        precomputedSeed: UInt64? = nil,
        collectDecodingReport: Bool = true
    ) -> FlatResult {
        let seed: UInt64
        let resolvedFallbackTree: ChoiceTree?
        let maximizeBoundRegionIndices: Set<Int>?

        switch mode {
            case .exact:
                // Same reasoning as materializeAny: with materializePicks off (always, here), the PRNG output is discarded in exact mode, so the prefix hash is skipped.
                seed = precomputedSeed ?? 0
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
            size: 100,
            maximizeBoundRegionIndices: maximizeBoundRegionIndices,
            materializePicks: false,
            skipTree: true,
            decodingReport: collectDecodingReport ? DecodingReport() : nil
        )
        context.flatOutput = ChoiceSequence()
        context.flatOutput!.reserveCapacity(64)

        do {
            guard let (value, _) = try generateRecursive(
                gen, with: (), context: &context, fallbackTree: resolvedFallbackTree
            ) else {
                var report = context.decodingReport
                report?.filterObservations = context.filterObservations
                switch mode {
                    case .exact: return .rejected(decodingReport: report)
                    case .guided: return .failed(decodingReport: report)
                }
            }
            var report = context.decodingReport
            report?.filterObservations = context.filterObservations
            return .success(value: value, sequence: context.flatOutput ?? ChoiceSequence(), decodingReport: report)
        } catch is RejectionError {
            var report = context.decodingReport
            report?.filterObservations = context.filterObservations
            return .rejected(decodingReport: report)
        } catch {
            var report = context.decodingReport
            report?.filterObservations = context.filterObservations
            return .failed(decodingReport: report)
        }
    }
}

// MARK: - Internal Types

extension Materializer {
    /// Sentinel thrown when exact mode encounters an out-of-range inner value or exhausted prefix.
    struct RejectionError: Error {}

    /// Internal mode enum — includes `.generate` for non-selected branch materialization.
    enum InternalMode: Equatable {
        /// Exact: reject out-of-range inner values, clamp bound values, no cursor suspension.
        case exact
        /// Guided: tiered resolution (prefix → fallback → PRNG), cursor suspension at binds.
        case guided
        /// Pure PRNG generation — used when no prefix or fallback is available.
        case generate
        /// Deterministic minimization — used for non-selected branches at pick sites. Produces the shortlex-simplest content so that pivot candidates start from a minimal baseline.
        case minimize
    }
}

extension Materializer.Mode {
    var internalMode: Materializer.InternalMode {
        switch self {
            case .exact: .exact
            case .guided: .guided
        }
    }
}

// MARK: - Recursive Engine

extension Materializer {
    /// Returns whether a candidate reading of a zip's children lands its cumulative per-child entry counts exactly on the prefix's parsed subtree boundaries.
    @inline(__always)
    static func zipChildBoundariesMatch(_ children: [ChoiceTree], from start: Int, ends: [Int]) -> Bool {
        guard children.count == ends.count else {
            return false
        }
        var boundary = start
        for (child, end) in zip(children, ends) {
            boundary += child.flattenedEntryCount
            if boundary != end {
                return false
            }
        }
        return true
    }

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

    static func generateRecursive(
        _ gen: AnyGenerator,
        with inputValue: Any,
        context: inout Context,
        fallbackTree: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        // Fuse switch to avoid overhead of copying `operation`
        switch gen {
            case let .pure(value):
                return (value, .just)

            case let .impure(.contramap(_, nextGen), continuation):
                // Transparent: no callee tree node — fallback passes through.
                return try handleContramap(
                    nextGen, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: fallbackTree,
                    continuationFallback: nil
                )

            case let .impure(.prune(nextGen), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handlePrune(
                    nextGen, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.pick(choices, totalWeight), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handlePick(
                    choices, totalWeight: totalWeight,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.chooseBits(min, max, tag, isRangeExplicit, scaling, typeTagPayload), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handleChooseBits(
                    min: min, max: max, tag: tag, isRangeExplicit: isRangeExplicit,
                    scaling: scaling, typeTagPayload: typeTagPayload,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.sequence(lengthGen, elementGen), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handleSequence(
                    lengthGen: lengthGen, elementGen: elementGen,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.zip(generators, _), continuation):
                let (calleeFallback, continuationFallback): (ChoiceTree?, ChoiceTree?)
                var prefixChildEnds: [Int]?
                if let fallbackTree,
                   case let .group(children, _) = fallbackTree, children.count == 2,
                   case let .group(inner, _) = children[0], inner.count == generators.count
                {
                    let isAmbiguousShape = generators.count == 2
                    if context.mode == .guided || isAmbiguousShape {
                        prefixChildEnds = context.cursor.zipChildSubtreeEnds(count: generators.count)
                    }
                    var useWrapperReading = true
                    if isAmbiguousShape, let prefixChildEnds {
                        let childrenStart = context.cursor.position + 1
                        let wrapperMatches = zipChildBoundariesMatch(inner, from: childrenStart, ends: prefixChildEnds)
                        let calleeMatches = zipChildBoundariesMatch(children, from: childrenStart, ends: prefixChildEnds)
                        if wrapperMatches == false, calleeMatches {
                            useWrapperReading = false
                        }
                    }
                    (calleeFallback, continuationFallback) = useWrapperReading
                        ? (children[0], children[1])
                        : (fallbackTree, nil)
                } else {
                    if context.mode == .guided {
                        prefixChildEnds = context.cursor.zipChildSubtreeEnds(count: generators.count)
                    }
                    calleeFallback = fallbackTree
                    continuationFallback = nil
                }
                return try handleZip(
                    generators, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback,
                    prefixChildEnds: prefixChildEnds
                )

            case let .impure(.just(value), continuation):
                let (_, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                let calleeStart = context.flatCount
                context.emitFlat(.just)
                return try runContinuation(
                    result: value, calleeChoiceTree: .just, calleeStart: calleeStart,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case let .impure(.getSize, continuation):
                // Prefer the active resize scope. Outside a resize, use context.size
                // (default 100 = max) so size-scaled generators expose their full
                // range. The fallback tree's `.getSize` is unreliable because
                // reflected trees may store a small size that narrows the range and
                // destroys values through clamping.
                let (_, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                let size = currentSize(&context)
                // Flat emission keeps the real .getSize leaf (it emits no entries and costs one box) so the bind handler can still detect getSize-binds and emit group markers for them.
                let calleeTree: ChoiceTree = context.skipTree && context.emitsFlat == false ? .just : .getSize(size)
                return try runContinuation(
                    result: size, calleeChoiceTree: calleeTree, calleeStart: context.flatCount,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, continuationFallback: continuationFallback
                )

            case let .impure(.resize(newSize, gen), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handleResize(
                    newSize: newSize, gen: gen,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.filter(gen, fingerprint, filterType, predicate, sourceLocation), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handleFilter(
                    gen, fingerprint: fingerprint, filterType: filterType,
                    predicate: predicate, sourceLocation: sourceLocation,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.classify(gen, _, _), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handlePassthrough(
                    gen, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.unique(gen, _, _), continuation):
                let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
                return try handlePassthrough(
                    gen, continuation: continuation, inputValue: inputValue,
                    context: &context, calleeFallback: calleeFallback,
                    continuationFallback: continuationFallback
                )

            case let .impure(.transform(kind, inner), continuation):
                return try handleTransform(
                    kind: kind, inner: inner,
                    continuation: continuation, inputValue: inputValue,
                    context: &context, fallbackTree: fallbackTree
                )
        }
    }

    // MARK: - Run Continuation

    @inline(__always)
    static func runContinuation(
        result: Any,
        calleeChoiceTree: ChoiceTree,
        calleeStart: Int,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        let nextGen = try continuation(result)

        if context.skipTree {
            if case let .pure(value) = nextGen {
                // Flat emission preserves the callee tree so bind can distinguish `.getSize` inners; other callees are dummies either way.
                return (value, context.emitsFlat ? calleeChoiceTree : .just)
            }
            // A non-pure continuation means the tree path would wrap [callee, continuation] in a pair group, whose open marker precedes entries that are already emitted. Everything after calleeStart is exactly the callee's span (nothing else has been appended since it finished), so the insert shifts only that span.
            if context.emitsFlat {
                context.flatOutput!.insert(.group(true), at: calleeStart)
            }
            if let (continuationResult, _) = try generateRecursive(
                nextGen, with: inputValue, context: &context,
                fallbackTree: continuationFallback
            ) {
                context.emitFlat(.group(false))
                return (continuationResult, .just)
            }
            return nil
        }

        // A pure continuation makes no choices and contributes no structure, so the result tree is exactly the callee's; recursing into the pure generator only produced a synthetic .just to discard. Past this check the continuation is always impure, so the group wrap is unconditional.
        if case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if let (continuationResult, innerChoiceTree) = try generateRecursive(
            nextGen, with: inputValue, context: &context,
            fallbackTree: continuationFallback
        ) {
            return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
        }
        return nil
    }
}

// MARK: - Context

extension Materializer {
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
        /// Only `DeleteByBranchPromotionEncoder` needs full branch alternatives.
        var materializePicks: Bool = false
        /// When `true`, tree construction sites return `.just` instead of real nodes. Used by the two-phase decoder: Phase 1 checks the property without allocating a tree; Phase 2 re-materializes with the real tree only after the property fails.
        var skipTree: Bool = false
        /// Flat-emission buffer. When non-nil, the walk appends each node's flattened entries here in exactly `ChoiceSequence.flatten` order, so the caller gets the sequence without building a tree. Requires `skipTree` (handlers must not also build real nodes) and `materializePicks == false` (flatten only emits the selected branch). Handlers still return trees, but they are dummies, except `.getSize` leaves, which survive so the bind handler can choose group markers over bind markers.
        var flatOutput: ChoiceSequence?
        /// Suppresses flat emission for sub-walks whose trees the tree path discards: a sequence's generate-mode length walk and the metamorphic inner walk (which bulk-appends its flattened real tree instead).
        var flatEmissionSuspended: Bool = false
        /// Accumulates per-coordinate resolution tier data for guided mode.
        /// Accumulates per-coordinate resolution tier data for guided mode.
        /// `nil` for exact mode and pure-generate mode.
        var decodingReport: DecodingReport?
        /// Per-fingerprint filter predicate observations accumulated during this materialization.
        var filterObservations: [UInt64: FilterObservation] = [:]

        /// Whether flat emission is active right now (a buffer exists and no discarded-tree sub-walk has suspended it).
        @inline(__always)
        var emitsFlat: Bool {
            flatOutput != nil && flatEmissionSuspended == false
        }

        /// The current flat-buffer length, which is the index the next emitted entry will occupy. Handlers snapshot this before walking their callee so `runContinuation` can retro-insert the pair-group open marker.
        @inline(__always)
        var flatCount: Int {
            flatOutput?.count ?? 0
        }

        /// Appends one entry to the flat buffer when emission is active.
        @inline(__always)
        mutating func emitFlat(_ entry: ChoiceSequenceValue) {
            if emitsFlat {
                flatOutput!.append(entry)
            }
        }
    }
}
