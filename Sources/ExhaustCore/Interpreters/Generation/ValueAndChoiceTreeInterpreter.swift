//
//  ValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

// MARK: - Academic Background

//
// Combines the dissertation's `generate` and `randomness` interpretations (Goldstein section 3.3.3) into a single pass that produces both the value and the ChoiceTree recording every decision. The ChoiceTree is Exhaust's extension — the dissertation uses flat choice sequences. Correctness relies on the factoring theorem (section 3.3.3, theorem 1): replaying the recorded randomness through the generator reproduces the original value.

/// Produces both a value and a ``ChoiceTree`` by walking the ``FreerMonad`` spine and recording each choice.
///
/// Builds the ``ChoiceTree`` that screening analysis, reduction, and replay consume downstream. ``ValueInterpreter`` produces only the value and skips tree construction — use it (via ``nextValueOnly()``) when the tree is not needed.
package struct ValueAndChoiceTreeInterpreter<FinalOutput>: ~Copyable, ExhaustIterator {
    public typealias Element = (value: FinalOutput, tree: ChoiceTree)

    let generator: Generator<FinalOutput>
    private var erasedGenerator: AnyGenerator?
    private(set) var context: GenerationContext

    /// Creates an interpreter for the given generator with optional pick materialization, seed, run cap, starting run index, and size override.
    ///
    /// - Parameter initialRunIndex: The absolute run index to start from. Defaults to 0. Use a non-zero value to partition generation into independent batches, where each batch covers a disjoint run-index range with independently derived PRNG states.
    public init(
        _ generator: Generator<FinalOutput>,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
        initialRunIndex: UInt64 = 0,
        sizeOverride: UInt64? = nil
    ) {
        self.generator = generator
        let prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        context = .init(
            maxRuns: maxRuns ?? 100,
            baseSeed: prng.seed,
            isFixed: false,
            size: sizeOverride ?? 0,
            prng: prng,
            materializePicks: materializePicks,
            runs: initialRunIndex
        )
        ExhaustLog.debug(
            category: .generation,
            event: "vacti",
            metadata: [
                "seed": "\(context.baseSeed)",
                "requested": "\(context.maxRuns)",
            ]
        )
    }

    /// The PRNG seed used for this interpreter's generation runs.
    public var baseSeed: UInt64 {
        context.baseSeed
    }

    /// Returns the PRNG seed and current state after the most recent generation step.
    package var randomNumberGeneratorSnapshot: (
        seed: UInt64,
        state: Xoshiro256.StateType
    ) {
        (context.prng.seed, context.prng.currentState)
    }

    /// Per-fingerprint filter predicate observations accumulated across all generation runs.
    public var filterObservations: [UInt64: FilterObservation] {
        context.filterObservations
    }

    /// Whether the run ended before `maxRuns` because a `unique` site exhausted its retry budget. The exhaustion itself only logs at warning level, so the sampling pipeline reads this to surface the truncation through the issue channel.
    package private(set) var uniqueExhaustionTruncatedRun = false

    // MARK: - Iterator

    public mutating func next() throws -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }
        context.beginUniqueDecisionRecording()

        if context.isFixed == false {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }
        context.deadlineNanoseconds = monotonicNanoseconds() + SharedInterpreterHelpers.perValueGenerationBudgetNanoseconds

        defer {
            context.runs += 1
        }

        if erasedGenerator == nil {
            erasedGenerator = generator.erase()
        }

        do {
            guard let (value, tree) = try Self.generateRecursiveAny(
                erasedGenerator!, context: &context
            ) else {
                return nil
            }
            // swiftlint:disable:next force_cast
            return (value as! FinalOutput, tree)
        } catch GeneratorError.uniqueBudgetExhausted {
            ExhaustLog.warning(
                category: .generation,
                event: "uniqueness_budget_exhausted",
                metadata: [
                    "unique_count": "\(context.runs)",
                    "requested": "\(context.maxRuns)",
                ]
            )
            uniqueExhaustionTruncatedRun = true
            context.runs = context.maxRuns
            return nil
        } catch GeneratorError.sparseValidityCondition {
            ExhaustLog.warning(
                category: .generation,
                event: "sparse_validity_condition",
                metadata: [
                    "run": "\(context.runs)",
                ]
            )
            return nil
        } catch GeneratorError.backtrackExhausted {
            ExhaustLog.warning(
                category: .generation,
                event: "backtrack_exhausted",
                metadata: [
                    "run": "\(context.runs)",
                ]
            )
            return nil
        }
    }

    // MARK: - Flat Emission

    /// Generates the next value and its flattened choice sequence without constructing a ``ChoiceTree``.
    ///
    /// The sequence is entry for entry what `ChoiceSequence.flatten` produces from ``next()``'s tree for the same run, and PRNG consumption, size, and `unique` decisions match exactly, so ``reproduceWithTree()`` afterwards rebuilds that tree on demand. Use this where the tree is read rarely: the fuzz loop's fresh draws hash and offer the sequence on every attempt but read the tree only for the few candidates that are admitted or fail, and building a tree only to flatten and drop it was 6% of a mutation-phase run.
    ///
    /// Requires `materializePicks == false`: flatten emits only the selected branch, so there is no flat form for materialized alternatives.
    public mutating func nextFlat() throws -> (value: FinalOutput, sequence: ChoiceSequence)? {
        precondition(context.materializePicks == false, "flat emission has no form for materialized pick alternatives")
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }
        context.beginUniqueDecisionRecording()

        if context.isFixed == false {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }
        context.deadlineNanoseconds = monotonicNanoseconds() + SharedInterpreterHelpers.perValueGenerationBudgetNanoseconds

        defer {
            context.runs += 1
        }

        if erasedGenerator == nil {
            erasedGenerator = generator.erase()
        }

        context.flatOutput = ChoiceSequence()
        context.flatOutput!.reserveCapacity(64)
        defer {
            context.flatOutput = nil
        }

        do {
            guard let (value, _) = try Self.generateRecursiveAny(
                erasedGenerator!, context: &context
            ) else {
                return nil
            }
            let sequence = context.flatOutput ?? ChoiceSequence()
            // swiftlint:disable:next force_cast
            return (value as! FinalOutput, sequence)
        } catch GeneratorError.uniqueBudgetExhausted {
            ExhaustLog.warning(
                category: .generation,
                event: "uniqueness_budget_exhausted",
                metadata: [
                    "unique_count": "\(context.runs)",
                    "requested": "\(context.maxRuns)",
                ]
            )
            uniqueExhaustionTruncatedRun = true
            context.runs = context.maxRuns
            return nil
        } catch GeneratorError.sparseValidityCondition {
            ExhaustLog.warning(
                category: .generation,
                event: "sparse_validity_condition",
                metadata: [
                    "run": "\(context.runs)",
                ]
            )
            return nil
        }
    }

    // MARK: - Value-Only Generation

    /// Generates the next value without constructing a ``ChoiceTree``.
    ///
    /// Delegates to ``ValueInterpreter``'s tree-free recursive engine, which shares the same ``GenerationContext`` (filter cache, unique dedup, PRNG). PRNG consumption is identical to ``next()`` so the run can be reproduced with tree construction via ``reproduceWithTree()``.
    ///
    /// Records the decisions accepted by reached `.unique` operations so a later tree-building reproduction repeats their retry paths without changing the persistent deduplication history.
    public mutating func nextValueOnly() throws -> FinalOutput? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }
        context.beginUniqueDecisionRecording()

        if context.isFixed == false {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }
        context.deadlineNanoseconds = monotonicNanoseconds() + SharedInterpreterHelpers.perValueGenerationBudgetNanoseconds

        defer { context.runs += 1 }
        do {
            if erasedGenerator == nil {
                erasedGenerator = generator.erase()
            }
            // swiftlint:disable:next force_cast
            return try ValueInterpreter<FinalOutput>.generateRecursiveAny(erasedGenerator!, context: &context) as! FinalOutput?
        } catch GeneratorError.uniqueBudgetExhausted {
            ExhaustLog.warning(
                category: .generation,
                event: "uniqueness_budget_exhausted",
                metadata: [
                    "unique_count": "\(context.runs)",
                    "requested": "\(context.maxRuns)",
                ]
            )
            uniqueExhaustionTruncatedRun = true
            context.runs = context.maxRuns
            return nil
        } catch GeneratorError.sparseValidityCondition {
            ExhaustLog.warning(
                category: .generation,
                event: "sparse_validity_condition",
                metadata: ["run": "\(context.runs)"]
            )
            return nil
        } catch GeneratorError.backtrackExhausted {
            ExhaustLog.warning(
                category: .generation,
                event: "backtrack_exhausted",
                metadata: ["run": "\(context.runs)"]
            )
            return nil
        }
    }

    /// Re-runs the most recent generation with full ``ChoiceTree`` construction.
    ///
    /// Call after ``nextValueOnly()`` returns a failing value to obtain the tree for reduction. Uses the same per-run seed derivation as the original generation, producing an identical value and PRNG consumption path, but with tree construction enabled.
    ///
    /// The run index is `runs - 1` because ``nextValueOnly()`` increments `runs` before returning.
    public mutating func reproduceWithTree() throws -> Element? {
        let failingRunIndex = context.runs - 1
        context.prng = Xoshiro256.derive(from: context.baseSeed, at: failingRunIndex)
        // Refresh the deadline: the absolute deadline armed for the original generation has been ticking through the property invocation, and a stale one could expire immediately.
        context.deadlineNanoseconds = monotonicNanoseconds() + SharedInterpreterHelpers.perValueGenerationBudgetNanoseconds

        let savedRuns = context.runs
        context.runs = failingRunIndex
        context.beginUniqueDecisionReplay()
        defer {
            context.endUniqueDecisionReplay()
            context.runs = savedRuns
        }

        if erasedGenerator == nil {
            erasedGenerator = generator.erase()
        }

        guard let (value, tree) = try Self.generateRecursiveAny(
            erasedGenerator!, context: &context
        ) else {
            return nil
        }
        guard context.replayedAllUniqueDecisions else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! FinalOutput, tree)
    }

    /// Re-runs the most recent generation with full ``ChoiceTree`` construction, falling back to ``ChoiceTree/just`` on a VI/VACTI parity break.
    ///
    /// Call after ``nextValueOnly()`` returns a failing value to obtain the tree for reduction. When ``reproduceWithTree()`` returns nil, the value-only and tree-building interpreters disagreed on PRNG consumption for the same run, breaking the parity invariant the fast sampling path depends on. The value is still a valid counterexample, so this method returns ``ChoiceTree/just`` (an unreducible tree); the log entry and assertion make the divergence observable rather than silent.
    public mutating func reproduceFailureTree() throws -> ChoiceTree {
        if let (_, tree) = try reproduceWithTree() {
            return tree
        }
        ExhaustLog.error(
            category: .propertyTest,
            event: "vacti_vi_parity_break",
            "reproduceWithTree returned nil after nextValueOnly produced a failing value"
        )
        assertionFailure("VI/VACTI parity break: reproduceWithTree returned nil after a failing nextValueOnly value")
        return .just
    }

    // MARK: - Generic Wrapper

    /// Typed entry point that erases to ``generateRecursiveAny`` and casts the result back.
    static func generateRecursive<Output>(
        _ gen: Generator<Output>,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        guard let (value, tree) = try generateRecursiveAny(
            gen.erase(), context: &context
        ) else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! Output, tree)
    }

    // MARK: - Recursive Engine

    /// Non-generic recursive engine operating entirely on type-erased generators and values.
    ///
    /// Walks the ``FreerMonad`` spine: `.pure` returns immediately; `.impure` dispatches the ``ReflectiveOperation`` to the appropriate handler (chooseBits, pick, sequence, filter, and so on), then feeds the result into the continuation. Forward generation carries no contramap input — prune and contramap are pass-throughs here; the backward direction is handled by the reflection interpreter.
    ///
    /// - Returns: The generated value paired with its choice tree, or `nil` if generation fails (for example, filter exhaustion or PRNG budget exceeded).
    /// The outer switch matches `.impure(.<operation>, continuation)` directly, enabling single-level dispatch without an intermediate operation variable.
    static func generateRecursiveAny(
        _ gen: AnyGenerator,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        switch gen {
            case let .pure(value):
                context.emitFlat(.just)
                return (value, .just)

        // MARK: chooseBits

            case let .impure(operation: .chooseBits(min, max, tag, isRangeExplicit, scaling, typeTagPayload), continuation):
                return try handleChooseBits(
                    min: min, max: max, tag: tag, isRangeExplicit: isRangeExplicit,
                    scaling: scaling, typeTagPayload: typeTagPayload,
                    continuation: continuation, context: &context
                )

        // MARK: just

            case let .impure(operation: .just(value), continuation):
                let calleeStart = context.flatCount
                context.emitFlat(.just)
                return try runContinuation(
                    result: value, calleeChoiceTree: .just, calleeStart: calleeStart,
                    continuation: continuation, context: &context
                )

        // MARK: getSize

            case .impure(operation: .getSize, let continuation):
                let size = SharedInterpreterHelpers.currentSize(&context)
                // A getSize leaf flattens to nothing and survives flat emission as a real node, so the bind handler can tell a getSize-bind (group markers) from a value bind.
                return try runContinuation(
                    result: size, calleeChoiceTree: .getSize(size), calleeStart: context.flatCount,
                    continuation: continuation, context: &context
                )

        // MARK: contramap

            case let .impure(operation: .contramap(_, innerGen), continuation):
                return try handleContramap(innerGen: innerGen, continuation: continuation, context: &context)

        // MARK: prune

            case let .impure(operation: .prune(innerGen), continuation):
                return try handlePrune(innerGen: innerGen, continuation: continuation, context: &context)

        // MARK: pick

            case let .impure(operation: .pick(choices, totalWeight), continuation):
                return try handlePick(
                    choices, totalWeight: totalWeight,
                    continuation: continuation, context: &context
                )

        // MARK: sequence

            case let .impure(operation: .sequence(lengthGen, elementGen, elementBatch), continuation):
                return try handleSequence(
                    lengthGen: lengthGen, elementGen: elementGen, elementBatch: elementBatch,
                    continuation: continuation, context: &context
                )

        // MARK: zip

            case let .impure(operation: .zip(generators, isOpaque), continuation):
                return try handleZip(
                    generators, isOpaque: isOpaque,
                    continuation: continuation, context: &context
                )

        // MARK: resize

            case let .impure(operation: .resize(newSize, resizeGen), continuation):
                return try handleResize(
                    newSize: newSize, resizeGen: resizeGen,
                    continuation: continuation, context: &context
                )

        // MARK: filter

            case let .impure(operation: .filter(filterGen, fingerprint, filterType, predicate, sourceLocation), continuation):
                return try handleFilter(
                    filterGen: filterGen, fingerprint: fingerprint, filterType: filterType,
                    predicate: predicate, sourceLocation: sourceLocation,
                    continuation: continuation, context: &context
                )

        // MARK: classify

            case let .impure(operation: .classify(classifyGen, fingerprint, classifiers), continuation):
                return try handleClassify(
                    classifyGen: classifyGen, fingerprint: fingerprint, classifiers: classifiers,
                    continuation: continuation, context: &context
                )

        // MARK: transform

            case let .impure(operation: .transform(kind, inner), continuation):
                return try handleTransform(
                    kind: kind, inner: inner,
                    continuation: continuation, context: &context
                )

        // MARK: unique

            case let .impure(operation: .unique(uniqueGen, fingerprint, keyExtractor), continuation):
                return try handleUnique(
                    uniqueGen: uniqueGen, fingerprint: fingerprint, keyExtractor: keyExtractor,
                    continuation: continuation, context: &context
                )
        }
    }

    // MARK: - Case Handlers

    //
    // Every `.impure` case body lives in an `@inline(__always)` handler rather than inline in the switch. See the Case Handlers note in ValueInterpreter for the debug stack-frame rationale; the same constraint applies here.

    // MARK: - Run Continuation

    /// Feeds the callee's result into the continuation and pair-groups the two subtrees when the continuation makes choices of its own.
    ///
    /// `calleeStart` is the flat-buffer index the callee's first entry occupies. Under flat emission the pair group's open marker has to precede entries that are already emitted, and everything from `calleeStart` on is exactly the callee's span, so retro-inserting there shifts only that span.
    @inline(__always)
    private static func runContinuation(
        result: Any,
        calleeChoiceTree: ChoiceTree,
        calleeStart: Int,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let nextGen = try continuation(result)

        if case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if context.emitsFlat {
            context.flatOutput!.insert(.group(true), at: calleeStart)
            guard let (continuationResult, _) = try generateRecursiveAny(
                nextGen, context: &context
            ) else {
                return nil
            }
            context.emitFlat(.group(false))
            return (continuationResult, .just)
        }
        guard let (continuationResult, innerChoiceTree) = try generateRecursiveAny(
            nextGen, context: &context
        ) else {
            return nil
        }
        return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
    }

    @inline(__always)
    private static func handlePick(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        totalWeight: UInt64,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        if choices[0].isBacktrack {
            return try handleBacktrack(choices, continuation: continuation, context: &context)
        }
        let branchCount = UInt64(choices.count)
        guard let selectedChoice = WeightedPickSelection.draw(
            from: choices, totalWeight: totalWeight,
            using: &context.prng
        ) else {
            return nil
        }
        let jumpSeed = context.prng.next()
        let fingerprint = choices[0].fingerprint

        if context.emitsFlat {
            // Mirrors flatten's selected-branch group: group open, branch marker, branch body plus continuation (pair-grouped by runContinuation when the continuation is impure), group close.
            context.emitFlat(.group(true))
            context.emitFlat(.branch(.init(
                id: selectedChoice.id,
                branchCount: branchCount,
                fingerprint: fingerprint
            )))
            let branchBodyStart = context.flatCount
            guard let result = try generateRecursiveAny(
                selectedChoice.generator,
                context: &context
            ),
                let final = try runContinuation(
                    result: result.0,
                    calleeChoiceTree: result.1,
                    calleeStart: branchBodyStart,
                    continuation: continuation,
                    context: &context
                )
            else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            context.emitFlat(.group(false))
            return (final.0, .just)
        }

        if context.materializePicks == false {
            let branchBodyStart = context.flatCount
            guard let result = try generateRecursiveAny(
                selectedChoice.generator,
                context: &context
            ),
                let final = try runContinuation(
                    result: result.0,
                    calleeChoiceTree: result.1,
                    calleeStart: branchBodyStart,
                    continuation: continuation,
                    context: &context
                )
            else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            let tree = ChoiceTree.branch(
                fingerprint: fingerprint,
                weight: selectedChoice.weight,
                id: selectedChoice.id,
                branchCount: branchCount,
                choice: final.1,
                isSelected: true
            )
            return (final.0, .group([tree]))
        }

        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        var finalValue: Any?

        for choice in choices {
            let isSelected = choice.id == selectedChoice.id
            var value: Any?
            var branch: ChoiceTree?

            if isSelected {
                if let result = try generateRecursiveAny(
                    choice.generator, context: &context
                ),
                    let final = try runContinuation(
                        result: result.0,
                        calleeChoiceTree: result.1,
                        calleeStart: 0,
                        continuation: continuation, context: &context
                    )
                {
                    value = final.0
                    branch = ChoiceTree.branch(
                        fingerprint: fingerprint,
                        weight: choice.weight,
                        id: choice.id,
                        branchCount: branchCount,
                        choice: final.1,
                        isSelected: true
                    )
                }
            } else {
                branch = try materializeUnselectedBranch(
                    choice,
                    fingerprint: fingerprint,
                    branchCount: branchCount,
                    jumpSeed: jumpSeed,
                    continuation: continuation,
                    context: &context
                )
            }

            if isSelected, let branch {
                finalValue = value
                branches.append(branch)
            } else if let branch {
                branches.append(branch)
            }
        }

        guard let value = finalValue else {
            throw GeneratorError.choiceTreeConstructionFailed
        }

        return (value, .group(branches))
    }

    /// Materializes an unselected pick branch on a context jumped from `jumpSeed`, or returns nil when the branch cannot produce a value.
    ///
    /// Best-effort: a branch whose filter cannot be satisfied, whose unique budget is exhausted, or whose backtrack node has no producing arm is skipped, exactly like a branch that produces nil. Only the selected branch's failures abort the run; without the catch, an unsatisfiable filter on an untaken branch kills runs that the value-only interpreter completes, breaking VI/VACTI parity.
    @inline(__always)
    private static func materializeUnselectedBranch(
        _ choice: ReflectiveOperation.PickTuple,
        fingerprint: UInt64,
        branchCount: UInt64,
        jumpSeed: UInt64,
        continuation: (Any) throws -> AnyGenerator,
        context: inout GenerationContext
    ) throws -> ChoiceTree? {
        var branchContext = context.jump(seed: jumpSeed)
        do {
            if let result = try generateRecursiveAny(
                choice.generator, context: &branchContext
            ),
                let final = try runContinuation(
                    result: result.0,
                    calleeChoiceTree: result.1,
                    calleeStart: branchContext.flatCount,
                    continuation: continuation, context: &branchContext
                )
            {
                return ChoiceTree.branch(
                    fingerprint: fingerprint,
                    weight: choice.weight,
                    id: choice.id,
                    branchCount: branchCount,
                    choice: final.1
                )
            }
        } catch GeneratorError.sparseValidityCondition, GeneratorError.uniqueBudgetExhausted, GeneratorError.backtrackExhausted {}
        return nil
    }

    /// Auditions the arms of a backtrack pick without replacement and records only the winner.
    ///
    /// The recorded node is an ordinary selected `.branch` carrying the winning arm's id and subtree, so every downstream pass reads it as a committed pick. A failed arm's draws stay consumed and its subtree is discarded; its value-side traces are rolled back because the value never reached the output. Under `materializePicks` the unselected arms are recorded on jumped contexts exactly as for a committed pick, seeded from the winning draw.
    @inline(__always)
    private static func handleBacktrack(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let branchCount = UInt64(choices.count)
        let fingerprint = choices[0].fingerprint
        var audition = BacktrackAudition(choices)
        var lastJumpSeed: UInt64 = 0
        var winner: (arm: ReflectiveOperation.PickTuple, result: (Any, ChoiceTree))?
        // Every arm's entries start here: a failed arm's are truncated by `restore`, so the winner's body begins at the same index whichever arm it is.
        let groupStart = context.flatCount
        while winner == nil, let (arm, jumpSeed) = audition.drawNext(using: &context.prng) {
            lastJumpSeed = jumpSeed
            let snapshot = context.auditionSnapshot()
            guard let result = try generateRecursiveAny(arm.generator, context: &context) else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            if isNilOptional(result.0) {
                context.restore(snapshot)
            } else {
                winner = (arm, result)
            }
        }
        if winner == nil {
            let absent = try BacktrackAudition.resolveExhaustion(of: choices, reportingDiagnostic: context.isSpeculative == false)
            guard let result = try generateRecursiveAny(absent.generator, context: &context) else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            winner = (absent, result)
        }
        let (arm, result) = winner!
        var calleeStart = groupStart
        if context.emitsFlat {
            // Mirrors flatten's selected-branch group, as in handlePick. The winner is only known after its body is emitted, so the group open and branch marker are inserted ahead of it rather than emitted before it.
            context.flatOutput!.insert(.branch(.init(
                id: arm.id,
                branchCount: branchCount,
                fingerprint: fingerprint
            )), at: groupStart)
            context.flatOutput!.insert(.group(true), at: groupStart)
            calleeStart = groupStart + 2
        }
        guard let final = try runContinuation(
            result: result.0,
            calleeChoiceTree: result.1,
            calleeStart: calleeStart,
            continuation: continuation,
            context: &context
        ) else {
            throw GeneratorError.choiceTreeConstructionFailed
        }
        if context.emitsFlat {
            context.emitFlat(.group(false))
            return (final.0, .just)
        }
        let selectedBranch = ChoiceTree.branch(
            fingerprint: fingerprint,
            weight: arm.weight,
            id: arm.id,
            branchCount: branchCount,
            choice: final.1,
            isSelected: true
        )
        if context.materializePicks == false {
            return (final.0, .group([selectedBranch]))
        }
        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        for choice in choices {
            if choice.id == arm.id {
                branches.append(selectedBranch)
            } else if let branch = try materializeUnselectedBranch(
                choice,
                fingerprint: fingerprint,
                branchCount: branchCount,
                jumpSeed: lastJumpSeed,
                continuation: continuation,
                context: &context
            ) {
                branches.append(branch)
            }
        }
        return (final.0, .group(branches))
    }

    @inline(__always)
    private static func handleSequence(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        elementBatch: ReflectiveOperation.SequenceElementBatch?,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        // The length walk builds a real tree even under flat emission: flatten never contains length entries, and the open marker below carries the length tree's metadata, which the tree path reads off the node.
        let lengthResult: (Any, ChoiceTree)?
        do {
            let savedSuspension = context.flatEmissionSuspended
            context.flatEmissionSuspended = true
            defer { context.flatEmissionSuspended = savedSuspension }
            lengthResult = try generateRecursiveAny(lengthGen.erase(), context: &context)
        }
        guard let (lengthValue, lengthTrees) = lengthResult else {
            return nil
        }
        // The length spine is `UInt64`-typed by construction; a non-`UInt64` value is a malformed generator, not a recoverable condition.
        // swiftlint:disable:next force_cast
        let length = lengthValue as! UInt64

        let count = try SharedInterpreterHelpers.sequenceElementCount(length)
        let lengthMetadata = lengthTrees.metadata
        let emitsFlat = context.emitsFlat
        let calleeStart = context.flatCount
        context.emitFlat(.sequence(
            true,
            validRange: lengthMetadata.validRange,
            isLengthExplicit: lengthMetadata.isRangeExplicit
        ))
        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(count)
        if emitsFlat == false {
            elements.reserveCapacity(count)
        }

        // Unwrap a forward-inert contramap layer before matching so character generators and similar wrappers can use the fused chooseBits loop.
        var fusedElementGen = elementGen
        var contramapContinuation: ((Any) throws -> AnyGenerator)?
        if case let .impure(
            operation: .contramap(_, innerGen),
            continuation: outerContinuation
        ) = elementGen {
            fusedElementGen = innerGen
            contramapContinuation = outerContinuation
        }

        // Hoist scaling out of the per-element loop: size is stable within a run, so applyScaling (which includes pow() for exponential) produces the same effective range for every element. Unscaled direct elements already optimize well under WMO; include them only when fusing away the contramap dispatch as well.
        if let elementBatch, case let .impure(
            operation: .chooseBits(min, max, tag, isRangeExplicit, scaling, typeTagPayload),
            _
        ) = fusedElementGen {
            let effectiveRange: ClosedRange<UInt64>
            if let scaling {
                let size = SharedInterpreterHelpers.currentSize(&context)
                effectiveRange = Gen.applyScaling(
                    min: min, max: max, tag: tag, scaling: scaling, size: size
                )
            } else {
                effectiveRange = min ... max
            }
            let metadata = ChoiceMetadata(
                validRange: min ... max,
                isRangeExplicit: isRangeExplicit,
                typeTagPayload: typeTagPayload
            )
            // Batch loop: same draws and distribution step as the fused loop below, with the pure element continuation replaced by one conversion of the collected bits.
            var bits: [UInt64] = []
            bits.reserveCapacity(count)
            for elementIndex in 0 ..< count {
                try SharedInterpreterHelpers.checkGenerationDeadline(context.deadlineNanoseconds, elementIndex: elementIndex)
                let rawBits = context.prng.next(in: effectiveRange)
                let randomBits = tag.isFloatingPoint
                    ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                    : rawBits
                bits.append(randomBits)
                if emitsFlat {
                    context.flatOutput!.append(.value(.init(
                        choice: ChoiceValue(randomBits, tag: tag),
                        validRange: metadata.validRange,
                        isRangeExplicit: metadata.isRangeExplicit
                    )))
                } else {
                    elements.append(.choice(ChoiceValue(randomBits, tag: tag), metadata))
                }
            }
            context.emitFlat(.sequence(false))
            let choiceTree: ChoiceTree = emitsFlat
                ? .just
                : .sequence(elements: elements, metadata: lengthMetadata)
            return try runContinuation(
                result: elementBatch.convert(bits),
                calleeChoiceTree: choiceTree,
                calleeStart: calleeStart,
                continuation: continuation,
                context: &context
            )
        } else if case let .impure(
            operation: .chooseBits(min, max, tag, isRangeExplicit, scaling, typeTagPayload),
            continuation: elementContinuation
        ) = fusedElementGen, scaling != nil || contramapContinuation != nil {
            let effectiveRange: ClosedRange<UInt64>
            if let scaling {
                let size = SharedInterpreterHelpers.currentSize(&context)
                effectiveRange = Gen.applyScaling(
                    min: min, max: max, tag: tag, scaling: scaling, size: size
                )
            } else {
                effectiveRange = min ... max
            }
            let metadata = ChoiceMetadata(
                validRange: min ... max,
                isRangeExplicit: isRangeExplicit,
                typeTagPayload: typeTagPayload
            )

            for elementIndex in 0 ..< count {
                try SharedInterpreterHelpers.checkGenerationDeadline(context.deadlineNanoseconds, elementIndex: elementIndex)
                let rawBits = context.prng.next(in: effectiveRange)
                let randomBits = tag.isFloatingPoint
                    ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                    : rawBits
                let elementStart = context.flatCount
                let calleeTree: ChoiceTree
                if emitsFlat {
                    context.flatOutput!.append(.value(.init(
                        choice: ChoiceValue(randomBits, tag: tag),
                        validRange: metadata.validRange,
                        isRangeExplicit: metadata.isRangeExplicit
                    )))
                    calleeTree = .just
                } else {
                    calleeTree = .choice(ChoiceValue(randomBits, tag: tag), metadata)
                }
                guard var (result, elementTree) = try runContinuation(
                    result: randomBits, calleeChoiceTree: calleeTree, calleeStart: elementStart,
                    continuation: elementContinuation, context: &context
                ) else {
                    return nil
                }
                if let contramapContinuation {
                    // The wrapper's callee is the whole element span, so its pair group opens at the element's start.
                    guard let continued = try runContinuation(
                        result: result,
                        calleeChoiceTree: elementTree,
                        calleeStart: elementStart,
                        continuation: contramapContinuation,
                        context: &context
                    ) else {
                        return nil
                    }
                    (result, elementTree) = continued
                }
                results.append(result)
                if emitsFlat == false {
                    elements.append(elementTree)
                }
            }
        } else {
            for elementIndex in 0 ..< count {
                try SharedInterpreterHelpers.checkGenerationDeadline(context.deadlineNanoseconds, elementIndex: elementIndex)
                guard let (result, element) = try generateRecursiveAny(
                    elementGen, context: &context
                ) else {
                    return nil
                }
                results.append(result)
                if emitsFlat == false {
                    elements.append(element)
                }
            }
        }

        context.emitFlat(.sequence(false))
        let choiceTree: ChoiceTree = emitsFlat
            ? .just
            : .sequence(elements: elements, metadata: lengthMetadata)

        if let continued = try runContinuation(
            result: results,
            calleeChoiceTree: choiceTree,
            calleeStart: calleeStart,
            continuation: continuation,
            context: &context
        ) {
            return continued
        }
        return nil
    }

    @inline(__always)
    private static func handleZip(
        _ generators: ContiguousArray<AnyGenerator>,
        isOpaque: Bool,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        let emitsFlat = context.emitsFlat
        if emitsFlat == false {
            choiceTrees.reserveCapacity(generators.count)
        }
        let calleeStart = context.flatCount
        context.emitFlat(.zip(true))

        for gen in generators {
            guard let (result, tree) = try generateRecursiveAny(
                gen,
                context: &context
            ) else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            results.append(result)
            if emitsFlat == false {
                choiceTrees.append(tree)
            }
        }
        context.emitFlat(.zip(false))
        let calleeTree: ChoiceTree = emitsFlat
            ? .just
            : .group(choiceTrees, isOpaque: isOpaque, isZip: true)
        return try runContinuation(
            result: results,
            calleeChoiceTree: calleeTree,
            calleeStart: calleeStart,
            continuation: continuation,
            context: &context
        )
    }

    @inline(__always)
    private static func handleTransform(
        kind: TransformKind,
        inner: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let result: Any
        let resultTree: ChoiceTree
        let calleeStart = context.flatCount
        switch kind {
            case let .map(forward, _, _, _), let .isomorph(forward, _, _, _):
                guard let (innerValue, innerTree) = try generateRecursiveAny(
                    inner, context: &context
                ) else {
                    return nil
                }
                result = try forward(innerValue)
                resultTree = innerTree
            case let .bind(fingerprint, forward, _, _, _):
                guard let (innerValue, innerTree) = try generateRecursiveAny(
                    inner, context: &context
                ) else {
                    return nil
                }
                // The marker kind depends on the inner's shape, known only after its walk, so the open marker is retro-inserted before the inner's span (empty for a getSize inner). Matches flatten's getSize-bind group rewrite.
                let isGetSizeBind = innerTree.isGetSize
                if context.emitsFlat {
                    context.flatOutput!.insert(isGetSizeBind ? .group(true) : .bind(true), at: calleeStart)
                }
                let boundGen = try forward(innerValue)
                let savedMaterializePicks = context.materializePicks
                context.materializePicks = false
                defer { context.materializePicks = savedMaterializePicks }
                guard let (boundValue, boundTree) = try generateRecursiveAny(
                    boundGen, context: &context
                ) else {
                    return nil
                }
                context.emitFlat(isGetSizeBind ? .group(false) : .bind(false))
                result = boundValue
                resultTree = context.emitsFlat
                    ? .just
                    : .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
            case let .metamorphic(transforms, _):
                let savedState = (context.prng.seed, context.prng.currentState)
                let seenSnapshot = (context.uniqueSeenKeys, context.uniqueSeenSequences)
                guard let (original, innerTree) = try generateRecursiveAny(
                    inner, context: &context
                ) else {
                    return nil
                }
                let seenAfterOriginal = (context.uniqueSeenKeys, context.uniqueSeenSequences)
                var results: [Any] = [original]
                results.reserveCapacity(transforms.count + 1)
                // Copies replay against the original's starting dedup state; see ReflectiveOperation.metamorphic. Their walks emit nothing: flatten carries the original's entries only.
                for transform in transforms {
                    context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                    (context.uniqueSeenKeys, context.uniqueSeenSequences) = seenSnapshot
                    let copyResult: (Any, ChoiceTree)?
                    do {
                        let savedSuspension = context.flatEmissionSuspended
                        context.flatEmissionSuspended = true
                        defer { context.flatEmissionSuspended = savedSuspension }
                        copyResult = try generateRecursiveAny(inner, context: &context)
                    }
                    guard let (copy, _) = copyResult else {
                        return nil
                    }
                    try results.append(transform(copy))
                }
                (context.uniqueSeenKeys, context.uniqueSeenSequences) = seenAfterOriginal
                result = results
                resultTree = innerTree
        }
        return try runContinuation(
            result: result,
            calleeChoiceTree: resultTree,
            calleeStart: calleeStart,
            continuation: continuation,
            context: &context
        )
    }

    @inline(__always)
    private static func handleChooseBits(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        typeTagPayload: TypeTagPayload?,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let effectiveRange: ClosedRange<UInt64>
        if let scaling {
            let size = SharedInterpreterHelpers.currentSize(&context)
            effectiveRange = Gen.applyScaling(
                min: min, max: max, tag: tag, scaling: scaling, size: size
            )
        } else {
            effectiveRange = min ... max
        }
        let rawBits = context.prng.next(in: effectiveRange)
        let randomBits = tag.isFloatingPoint
            ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
            : rawBits
        let calleeStart = context.flatCount
        let calleeTree: ChoiceTree
        if context.emitsFlat {
            context.flatOutput!.append(.value(.init(
                choice: ChoiceValue(randomBits, tag: tag),
                validRange: min ... max,
                isRangeExplicit: isRangeExplicit
            )))
            calleeTree = .just
        } else {
            calleeTree = .choice(
                ChoiceValue(randomBits, tag: tag),
                .init(validRange: min ... max, isRangeExplicit: isRangeExplicit, typeTagPayload: typeTagPayload)
            )
        }
        return try runContinuation(
            result: randomBits, calleeChoiceTree: calleeTree, calleeStart: calleeStart,
            continuation: continuation, context: &context
        )
    }

    @inline(__always)
    private static func handleContramap(
        innerGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let calleeStart = context.flatCount
        guard let (result, tree) = try generateRecursiveAny(
            innerGen, context: &context
        ) else { return nil }
        return try runContinuation(
            result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
            continuation: continuation, context: &context
        )
    }

    @inline(__always)
    private static func handlePrune(
        innerGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        // Forward generation never prunes (reflection-only), so the operation is a pass-through here.
        let calleeStart = context.flatCount
        guard let (result, tree) = try generateRecursiveAny(
            innerGen, context: &context
        ) else { return nil }
        return try runContinuation(
            result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
            continuation: continuation, context: &context
        )
    }

    @inline(__always)
    private static func handleResize(
        newSize: UInt64,
        resizeGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let previousSizeOverride = context.sizeOverride
        let calleeStart = context.flatCount
        context.emitFlat(.group(true))
        let innerResult: (Any, ChoiceTree)?
        do {
            context.sizeOverride = newSize
            defer { context.sizeOverride = previousSizeOverride }
            innerResult = try generateRecursiveAny(
                resizeGen,
                context: &context
            )
        }
        guard let innerResult else { return nil }
        context.emitFlat(.group(false))
        let calleeTree: ChoiceTree = context.emitsFlat
            ? .just
            : .resize(newSize: newSize, choices: [innerResult.1])
        return try runContinuation(
            result: innerResult.0, calleeChoiceTree: calleeTree, calleeStart: calleeStart,
            continuation: continuation, context: &context
        )
    }

    @inline(__always)
    private static func handleFilter(
        filterGen: AnyGenerator,
        fingerprint: UInt64,
        filterType: FilterType,
        predicate: @escaping (Any) -> Bool,
        sourceLocation: FilterSourceLocation,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        // Rejection-sampling filters never consult the tuned-filter cache, so they skip both the resolve call and the re-entrancy guard. For tuned filters, a fingerprint already being expanded higher on the path must not resolve: the cached chain contains this node and would recurse forever. The embedded inner is the correct local generator in both fallback cases (already tuned when the chain came from a tuning pass).
        let mustResolve = filterType != .rejectionSampling && context.filterExpansionPath.contains(fingerprint) == false
        if mustResolve {
            context.filterExpansionPath.append(fingerprint)
        }
        defer {
            if mustResolve {
                context.filterExpansionPath.removeLast()
            }
        }
        let filteredGen = mustResolve
            ? context.resolveTunedFilterMemoized(
                fingerprint: fingerprint,
                generator: filterGen,
                predicate: predicate,
                type: filterType
            )
            : filterGen
        var attempts = 0 as UInt64
        let observationDefault = FilterObservation(sourceLocation: sourceLocation, filterType: filterType)
        var filterAttempts = 0
        var filterPasses = 0
        defer {
            if filterAttempts > 0 {
                context.filterObservations[fingerprint, default: observationDefault]
                    .merge(FilterObservation(attempts: filterAttempts, passes: filterPasses))
            }
        }
        while attempts < GenerationContext.maxFilterRuns {
            let calleeStart = context.flatCount
            guard let (result, tree) = try Self.generateRecursiveAny(
                filteredGen, context: &context
            ) else { return nil }
            let passed = predicate(result)
            filterAttempts += 1
            if passed { filterPasses += 1 }
            if passed {
                return try runContinuation(
                    result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
                    continuation: continuation, context: &context
                )
            }
            // A rejected attempt's tree is dropped on the tree path; drop its emissions the same way so the retry re-emits from the same index.
            context.flatOutput?.removeSubrange(calleeStart...)
            attempts += 1
        }
        sourceLocation.onBudgetExhausted?()
        throw GeneratorError.sparseValidityCondition
    }

    @inline(__always)
    private static func handleClassify(
        classifyGen: AnyGenerator,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let calleeStart = context.flatCount
        guard let (result, tree) = try generateRecursiveAny(
            classifyGen, context: &context
        ) else { return nil }
        for (label, classifier) in classifiers where classifier(result) {
            context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
        }
        return try runContinuation(
            result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
            continuation: continuation, context: &context
        )
    }

    @inline(__always)
    private static func handleUnique(
        uniqueGen: AnyGenerator,
        fingerprint: UInt64,
        keyExtractor: ((Any) -> AnyHashable)?,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        var attempts = 0 as UInt64
        while attempts < GenerationContext.maxFilterRuns {
            let calleeStart = context.flatCount
            guard let (result, tree) = try Self.generateRecursiveAny(
                uniqueGen, context: &context
            ) else { return nil }
            let accepted: Bool
            if let keyExtractor {
                let key = keyExtractor(result)
                accepted = context.acceptUniqueKey(key, fingerprint: fingerprint)
            } else {
                // Under flat emission the inner's entries are already in the buffer from calleeStart on, and rebasing them at zero matches flattening the subtree on its own.
                let sequence = context.emitsFlat
                    ? ChoiceSequence(context.flatOutput![calleeStart...])
                    : ChoiceSequence.flatten(tree)
                accepted = context.acceptUniqueChoiceSequence(
                    hash: sequence.operativeHash,
                    fingerprint: fingerprint
                )
            }
            if accepted {
                return try runContinuation(
                    result: result, calleeChoiceTree: tree, calleeStart: calleeStart,
                    continuation: continuation, context: &context
                )
            }
            context.flatOutput?.removeSubrange(calleeStart...)
            attempts += 1
        }
        throw GeneratorError.uniqueBudgetExhausted
    }
}
