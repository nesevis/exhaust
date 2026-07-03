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
/// Builds the ``ChoiceTree`` that coverage analysis, reduction, and replay consume downstream. ``ValueInterpreter`` produces only the value and skips tree construction — use it (via ``nextValueOnly()``) when the tree is not needed.
package struct ValueAndChoiceTreeInterpreter<FinalOutput>: ~Copyable, ExhaustIterator {
    public typealias Element = (value: FinalOutput, tree: ChoiceTree)

    let generator: Generator<FinalOutput>
    private var erasedGenerator: AnyGenerator?
    private(set) var context: GenerationContext

    /// Creates an interpreter for the given generator with optional pick materialization, seed, run cap, starting run index, and size override.
    ///
    /// - Parameter initialRunIndex: The absolute run index to start from. Defaults to 0. Use a non-zero value to partition generation into independent batches — each batch covers a disjoint run-index range with independently derived PRNG states.
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

    /// Per-fingerprint filter predicate observations accumulated across all generation runs.
    public var filterObservations: [UInt64: FilterObservation] {
        context.filterObservations
    }

    // MARK: - Iterator

    public mutating func next() throws -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }

        if context.isFixed == false {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }

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
    /// Falls back to tree-building generation (discarding the tree) when the generator contains a choice-sequence-based `.unique` site, because the value-only path cannot safely reproduce the dedup without a tree.
    public mutating func nextValueOnly() throws -> FinalOutput? {
        if context.uniqueSeenSequences.isEmpty == false {
            return try next()?.value
        }

        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }

        if context.isFixed == false {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }

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
            context.runs = context.maxRuns
            return nil
        } catch GeneratorError.sparseValidityCondition {
            ExhaustLog.warning(
                category: .generation,
                event: "sparse_validity_condition",
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

        let savedRuns = context.runs
        context.runs = failingRunIndex
        defer { context.runs = savedRuns }

        if erasedGenerator == nil {
            erasedGenerator = generator.erase()
        }

        guard let (value, tree) = try Self.generateRecursiveAny(
            erasedGenerator!, context: &context
        ) else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! FinalOutput, tree)
    }

    /// Re-runs the most recent generation with full ``ChoiceTree`` construction, falling back to ``ChoiceTree/just`` on a VI/VACTI parity break.
    ///
    /// Call after ``nextValueOnly()`` returns a failing value to obtain the tree for reduction. When ``reproduceWithTree()`` returns nil, the value-only and tree-building interpreters disagreed on PRNG consumption for the same run — the parity invariant the fast sampling path depends on. The value is still a valid counterexample, so this method returns ``ChoiceTree/just`` (an unreducible tree); the log entry and assertion make the divergence observable rather than silent.
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
                return (value, .just)

        // MARK: chooseBits

            case let .impure(operation: .chooseBits(min, max, tag, isRangeExplicit, scaling, typeTagPayload), continuation):
                let effectiveRange: ClosedRange<UInt64>
                if let scaling {
                    let size = consumeSize(&context)
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
                let calleeTree = ChoiceTree.choice(
                    ChoiceValue(randomBits, tag: tag),
                    .init(validRange: min ... max, isRangeExplicit: isRangeExplicit, typeTagPayload: typeTagPayload)
                )
                return try runContinuation(
                    result: randomBits, calleeChoiceTree: calleeTree,
                    continuation: continuation, context: &context
                )

        // MARK: just

            case let .impure(operation: .just(value), continuation):
                return try runContinuation(
                    result: value, calleeChoiceTree: .just,
                    continuation: continuation, context: &context
                )

        // MARK: getSize

            case .impure(operation: .getSize, let continuation):
                let size = Self.consumeSize(&context)
                return try runContinuation(
                    result: size, calleeChoiceTree: .getSize(size),
                    continuation: continuation, context: &context
                )

        // MARK: contramap

            case let .impure(operation: .contramap(_, innerGen), continuation):
                guard let (result, tree) = try generateRecursiveAny(
                    innerGen, context: &context
                ) else { return nil }
                return try runContinuation(
                    result: result, calleeChoiceTree: tree,
                    continuation: continuation, context: &context
                )

        // MARK: prune

            case let .impure(operation: .prune(innerGen), continuation):
                // Forward generation never prunes (reflection-only), so the operation is a pass-through here.
                guard let (result, tree) = try generateRecursiveAny(
                    innerGen, context: &context
                ) else { return nil }
                return try runContinuation(
                    result: result, calleeChoiceTree: tree,
                    continuation: continuation, context: &context
                )

        // MARK: pick

            case let .impure(operation: .pick(choices, totalWeight), continuation):
                return try handlePick(
                    choices, totalWeight: totalWeight,
                    continuation: continuation, context: &context
                )

        // MARK: sequence

            case let .impure(operation: .sequence(lengthGen, elementGen), continuation):
                return try handleSequence(
                    lengthGen: lengthGen, elementGen: elementGen,
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
                context.sizeOverride = newSize
                defer { context.sizeOverride = nil }
                guard let result = try generateRecursiveAny(
                    resizeGen, context: &context
                ) else { return nil }
                let calleeTree = ChoiceTree.resize(newSize: newSize, choices: [result.1])
                return try runContinuation(
                    result: result.0, calleeChoiceTree: calleeTree,
                    continuation: continuation, context: &context
                )

        // MARK: filter

            case let .impure(operation: .filter(filterGen, fingerprint, filterType, predicate, sourceLocation), continuation):
                let filteredGen = GenerationContext.resolveTunedFilter(
                    fingerprint: fingerprint,
                    generator: filterGen,
                    predicate: predicate,
                    type: filterType
                )
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
                    guard let (result, tree) = try Self.generateRecursiveAny(
                        filteredGen, context: &context
                    ) else { return nil }
                    let passed = predicate(result)
                    filterAttempts += 1
                    if passed { filterPasses += 1 }
                    if passed {
                        return try runContinuation(
                            result: result, calleeChoiceTree: tree,
                            continuation: continuation, context: &context
                        )
                    }
                    attempts += 1
                }
                sourceLocation.onBudgetExhausted?()
                throw GeneratorError.sparseValidityCondition

        // MARK: classify

            case let .impure(operation: .classify(classifyGen, fingerprint, classifiers), continuation):
                guard let (result, tree) = try generateRecursiveAny(
                    classifyGen, context: &context
                ) else { return nil }
                for (label, classifier) in classifiers where classifier(result) {
                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
                }
                return try runContinuation(
                    result: result, calleeChoiceTree: tree,
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
                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let (result, tree) = try Self.generateRecursiveAny(
                        uniqueGen, context: &context
                    ) else { return nil }
                    let isDuplicate: Bool
                    if let keyExtractor {
                        let key = keyExtractor(result)
                        isDuplicate = context.uniqueSeenKeys[fingerprint, default: []].insert(key).inserted == false
                    } else {
                        let sequence = ChoiceSequence.flatten(tree)
                        isDuplicate = context.uniqueSeenSequences[fingerprint, default: []].insert(sequence).inserted == false
                    }
                    if isDuplicate == false {
                        return try runContinuation(
                            result: result, calleeChoiceTree: tree,
                            continuation: continuation, context: &context
                        )
                    }
                    attempts += 1
                }
                throw GeneratorError.uniqueBudgetExhausted
        }
    }

    // MARK: - Run Continuation

    @inline(__always)
    private static func runContinuation(
        result: Any,
        calleeChoiceTree: ChoiceTree,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let nextGen = try continuation(result)

        if case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
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
        let branchCount = UInt64(choices.count)
        guard let selectedChoice = WeightedPickSelection.draw(
            from: choices, totalWeight: totalWeight,
            using: &context.prng
        ) else {
            return nil
        }
        let jumpSeed = context.prng.next()
        let fingerprint = choices[0].fingerprint

        if context.materializePicks == false {
            guard let result = try generateRecursiveAny(
                selectedChoice.generator,
                context: &context
            ),
                let final = try runContinuation(
                    result: result.0,
                    calleeChoiceTree: result.1,
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
                var branchContext = context.jump(seed: jumpSeed)
                if let result = try generateRecursiveAny(
                    choice.generator, context: &branchContext
                ),
                    let final = try runContinuation(
                        result: result.0,
                        calleeChoiceTree: result.1,
                        continuation: continuation, context: &branchContext
                    )
                {
                    value = final.0
                    branch = ChoiceTree.branch(
                        fingerprint: fingerprint,
                        weight: choice.weight,
                        id: choice.id,
                        branchCount: branchCount,
                        choice: final.1
                    )
                }
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

    @inline(__always)
    static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        SharedInterpreterHelpers.consumeSize(&context)
    }

    @inline(__always)
    private static func handleSequence(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        guard let (lengthValue, lengthTrees) = try generateRecursiveAny(
            lengthGen.erase(), context: &context
        ) else {
            return nil
        }
        // The length spine is `UInt64`-typed by construction; a non-`UInt64` value is a malformed generator, not a recoverable condition.
        // swiftlint:disable:next force_cast
        let length = lengthValue as! UInt64

        let count = try SharedInterpreterHelpers.sequenceElementCount(length)
        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(count)
        elements.reserveCapacity(count)

        // Hoist scaling out of the per-element loop: size is stable within a run, so applyScaling (which includes pow() for exponential) produces the same effective range for every element.
        if case let .impure(
            operation: .chooseBits(min, max, tag, isRangeExplicit, .some(scaling), typeTagPayload),
            continuation: elementContinuation
        ) = elementGen, context.sizeOverride == nil {
            let size = consumeSize(&context)
            let effectiveRange = Gen.applyScaling(
                min: min, max: max, tag: tag, scaling: scaling, size: size
            )
            let metadata = ChoiceMetadata(validRange: min ... max, isRangeExplicit: isRangeExplicit, typeTagPayload: typeTagPayload)

            for _ in 0 ..< count {
                let rawBits = context.prng.next(in: effectiveRange)
                let randomBits = tag.isFloatingPoint
                    ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                    : rawBits
                let calleeTree = ChoiceTree.choice(ChoiceValue(randomBits, tag: tag), metadata)
                guard let (result, elementTree) = try runContinuation(
                    result: randomBits, calleeChoiceTree: calleeTree,
                    continuation: elementContinuation, context: &context
                ) else {
                    return nil
                }
                results.append(result)
                elements.append(elementTree)
            }
        } else {
            for _ in 0 ..< count {
                guard let (result, element) = try generateRecursiveAny(
                    elementGen, context: &context
                ) else {
                    return nil
                }
                results.append(result)
                elements.append(element)
            }
        }

        let choiceTree = ChoiceTree.sequence(
            length: length,
            elements: elements,
            lengthTrees.metadata
        )

        if let continued = try runContinuation(
            result: results,
            calleeChoiceTree: choiceTree,
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
        choiceTrees.reserveCapacity(generators.count)

        for gen in generators {
            guard let (result, tree) = try generateRecursiveAny(
                gen,
                context: &context
            ) else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            results.append(result)
            choiceTrees.append(tree)
        }
        return try runContinuation(
            result: results,
            calleeChoiceTree: .group(choiceTrees, isOpaque: isOpaque),
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
                let boundGen = try forward(innerValue)
                let savedMaterializePicks = context.materializePicks
                context.materializePicks = false
                defer { context.materializePicks = savedMaterializePicks }
                guard let (boundValue, boundTree) = try generateRecursiveAny(
                    boundGen, context: &context
                ) else {
                    return nil
                }
                result = boundValue
                resultTree = .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
            case let .metamorphic(transforms, _):
                let savedState = (context.prng.seed, context.prng.currentState)
                guard let (original, innerTree) = try generateRecursiveAny(
                    inner, context: &context
                ) else {
                    return nil
                }
                var results: [Any] = [original]
                results.reserveCapacity(transforms.count + 1)
                for transform in transforms {
                    context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                    guard let (copy, _) = try generateRecursiveAny(
                        inner, context: &context
                    ) else {
                        return nil
                    }
                    try results.append(transform(copy))
                }
                result = results
                resultTree = innerTree
        }
        return try runContinuation(
            result: result,
            calleeChoiceTree: resultTree,
            continuation: continuation,
            context: &context
        )
    }
}
