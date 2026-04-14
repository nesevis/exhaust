//
//  Materializer.swift
//  Exhaust
//

/// Materializer that always produces a fresh ``ChoiceTree`` with current ``validRange`` metadata
/// and all branch alternatives at pick sites.
///
/// This materializer:
/// - Rebuilds the tree from the generator on every invocation (no stale metadata).
/// - Materializes all branch alternatives at pick sites (``DeleteByBranchPromotionEncoder`` sees candidates).
/// - Supports exact and guided modes with inner-reject/bound-clamp semantics.
///
/// Guided mode computes the canonical cartesian lift in the simple fibration over trace space. The trace space is fibred: the base is the set of trace structures (which choice points exist and what controls them), and above each structure sits a fibre — the set of value assignments compatible with that structure. A structural reduction is a morphism in the base; guided mode lifts it canonically by replaying the current value assignment into the new fibre, carrying forward each value where it fits in the new domain and falling back to the fallback tree or PRNG otherwise. The three-tier resolution (prefix → fallback tree → PRNG) approximates this lift for the common case where the new domain is a strict subset of the old domain and the carried-forward value would be out of range. The canonical lift itself — carrying the value unchanged — is the unique cartesian morphism in the simple fibration (Jacobs, *Categorical Logic and Type Theory*, 1999, §1.4).
///
/// The result intentionally omits ``ChoiceSequence`` — the caller flattens `result.tree` to get a sequence with fresh metadata. The tree is the single source of truth.
public enum Materializer {
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
    ///
    /// All cases carry an optional ``DecodingReport`` containing resolution tier counts and per-fingerprint filter observations from the materialization pass.
    public enum Result<Output> {
        /// Materialization succeeded with a value and fresh tree.
        case success(value: Output, tree: ChoiceTree, decodingReport: DecodingReport?)
        /// Exact mode: out-of-range or structural mismatch — candidate is invalid.
        case rejected(decodingReport: DecodingReport?)
        /// Guided mode: filter or generation failure.
        case failed(decodingReport: DecodingReport?)
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
        materializePicks: Bool = false,
        precomputedSeed: UInt64? = nil
    ) -> Result<Output> {
        // Generic public entry point — erases the input generator and casts the result back to ``Output`` at the boundary, delegating to the non-generic ``materializeAny``. Hot-path callers (schedulers, decoders) should hold an already-erased ``ReflectiveGenerator<Any>`` and call ``materializeAny`` directly to avoid the per-call erasure cost.
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

    /// Non-generic materialization entry point that takes an already-erased generator.
    ///
    /// This is the hot-path API used by the reduction pipeline. By eliminating the `<Output>` generic parameter on the recursive descent, the runtime no longer pays per-Output-type metadata cache lookups inside ``generateRecursive``. Callers that hold a typed ``ReflectiveGenerator`` should use the generic ``materialize(_:prefix:mode:fallbackTree:materializePicks:precomputedSeed:)`` overload, which erases at the boundary and forwards here.
    public static func materializeAny(
        _ gen: ReflectiveGenerator<Any>,
        prefix: consuming ChoiceSequence,
        mode: Mode,
        fallbackTree: ChoiceTree? = nil,
        materializePicks: Bool = false,
        precomputedSeed: UInt64? = nil
    ) -> Result<Any> {
        let seed: UInt64
        let resolvedFallbackTree: ChoiceTree?
        let maximizeBoundRegionIndices: Set<Int>?

        switch mode {
        case .exact:
            seed = precomputedSeed ?? ZobristHash.hash(of: prefix)
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
            materializePicks: materializePicks,
            decodingReport: DecodingReport()
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

// MARK: - Internal Types

extension Materializer {
    /// Sentinel thrown when exact mode encounters an out-of-range inner value or exhausted prefix.
    struct RejectionError: Error {}

    /// Internal mode enum — includes `.generate` for non-selected branch materialization.
    enum InternalMode {
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

    var isGuided: Bool {
        switch self {
        case .exact: false
        case .guided: true
        }
    }
}

// MARK: - Recursive Engine

extension Materializer {
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
        _ gen: ReflectiveGenerator<Any>,
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

        case let .impure(.pick(choices), continuation):
            let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            return try handlePick(
                choices, continuation: continuation, inputValue: inputValue,
                context: &context, calleeFallback: calleeFallback,
                continuationFallback: continuationFallback
            )

        case let .impure(.chooseBits(min, max, tag, isRangeExplicit), continuation):
            let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            return try handleChooseBits(
                min: min, max: max, tag: tag, isRangeExplicit: isRangeExplicit,
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

        case let .impure(.just(value), continuation):
            let (_, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            return try runContinuation(
                result: value, calleeChoiceTree: .just,
                continuation: continuation, inputValue: inputValue,
                context: &context, continuationFallback: continuationFallback
            )

        case let .impure(.getSize, continuation):
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

        case let .impure(.resize(newSize, gen), continuation):
            let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            return try handleResize(
                newSize: newSize, gen: gen,
                continuation: continuation, inputValue: inputValue,
                context: &context, calleeFallback: calleeFallback,
                continuationFallback: continuationFallback
            )

        case let .impure(.filter(gen, fingerprint, _, predicate), continuation):
            let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            guard let (result, tree) = try generateRecursive(
                gen, with: inputValue, context: &context, fallbackTree: calleeFallback
            ) else { return nil }
            let passed = predicate(result)
            context.filterObservations[fingerprint, default: FilterObservation()]
                .recordAttempt(passed: passed)
            guard passed else { return nil }
            return try runContinuation(
                result: result, calleeChoiceTree: tree,
                continuation: continuation, inputValue: inputValue,
                context: &context, continuationFallback: continuationFallback
            )

        case let .impure(.classify(gen, _, _), continuation):
            let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            guard let (result, tree) = try generateRecursive(
                gen, with: inputValue, context: &context, fallbackTree: calleeFallback
            ) else { return nil }
            return try runContinuation(
                result: result, calleeChoiceTree: tree,
                continuation: continuation, inputValue: inputValue,
                context: &context, continuationFallback: continuationFallback
            )

        case let .impure(.unique(gen, _, _), continuation):
            let (calleeFallback, continuationFallback) = decomposeNonGroupFallback(fallbackTree)
            guard let (result, tree) = try generateRecursive(
                gen, with: inputValue, context: &context, fallbackTree: calleeFallback
            ) else { return nil }
            return try runContinuation(
                result: result, calleeChoiceTree: tree,
                continuation: continuation, inputValue: inputValue,
                context: &context, continuationFallback: continuationFallback
            )

        case let .impure(.transform(.map(forward, inputType, outputType), inner), continuation):
            // Transparent: no callee tree node — fallback passes through.
            return try handleTransform(
                kind: .map(forward: forward, inputType: inputType, outputType: outputType),
                inner: inner,
                continuation: continuation, inputValue: inputValue,
                context: &context, calleeFallback: fallbackTree,
                continuationFallback: nil
            )

        case let .impure(
            .transform(.bind(forward, backward, inputType, outputType), inner),
            continuation
        ):
            let (calleeFallback, continuationFallback) =
                decomposeNonGroupFallback(fallbackTree)
            return try handleTransform(
                kind: .bind(
                    forward: forward, backward: backward,
                    inputType: inputType, outputType: outputType
                ),
                inner: inner,
                continuation: continuation, inputValue: inputValue,
                context: &context, calleeFallback: calleeFallback,
                continuationFallback: continuationFallback
            )

        case let .impure(.transform(.metamorphic(transforms, inputType), inner), continuation):
            // Transparent: no callee tree node — fallback passes through (same as .map).
            return try handleTransform(
                kind: .metamorphic(transforms: transforms, inputType: inputType),
                inner: inner,
                continuation: continuation, inputValue: inputValue,
                context: &context, calleeFallback: fallbackTree,
                continuationFallback: nil
            )
        }
    }

    // MARK: - Run Continuation

    @inline(__always)
    static func runContinuation(
        result: Any,
        calleeChoiceTree: ChoiceTree,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout Context,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
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
        /// Accumulates per-coordinate resolution tier data for guided mode.
        /// `nil` for exact mode and pure-generate mode.
        var decodingReport: DecodingReport?
        /// Per-fingerprint filter predicate observations accumulated during this materialization.
        var filterObservations: [UInt64: FilterObservation] = [:]
    }
}

// MARK: - InternalMode Equatable

extension Materializer.InternalMode: Equatable {}
