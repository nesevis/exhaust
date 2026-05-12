//
//  ValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

// MARK: - Academic Provenance

//
// Combines the dissertation's `generate` and `randomness` interpretations (Goldstein §3.3.3) into a single pass that produces both the value and the ChoiceTree recording every decision. The ChoiceTree is Exhaust's extension — the dissertation uses flat choice sequences. Correctness relies on the factoring theorem (§4.4): replaying the recorded randomness through the generator reproduces the original value.

/// Produces both a value and a ``ChoiceTree`` by walking the ``FreerMonad`` spine and recording each choice.
///
/// This is the primary generation interpreter. The ``ChoiceTree`` it builds is consumed downstream by coverage analysis, reduction, and replay. When only the value is needed, ``nextValueOnly()`` delegates to ``ValueInterpreter`` to avoid tree construction overhead.
package struct ValueAndChoiceTreeInterpreter<FinalOutput>: ~Copyable, ExhaustIterator {
    public typealias Element = (value: FinalOutput, tree: ChoiceTree)

    let generator: ReflectiveGenerator<FinalOutput>
    private var erasedGenerator: ReflectiveGenerator<Any>?
    private(set) var context: GenerationContext

    /// Creates an interpreter for the given generator with optional pick materialization, seed, run cap, and size override.
    public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
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
            materializePicks: materializePicks
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

        if !context.isFixed {
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
                erasedGenerator!, with: (), context: &context
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

        if !context.isFixed {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }

        defer { context.runs += 1 }
        do {
            if erasedGenerator == nil {
                erasedGenerator = generator.erase()
            }
            // swiftlint:disable:next force_cast
            return try ValueInterpreter<FinalOutput>.generateRecursiveAny(erasedGenerator!, with: (), context: &context) as! FinalOutput?
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
            erasedGenerator!, with: (), context: &context
        ) else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! FinalOutput, tree)
    }

    /// Used to generate results around a similar level of complexity. Intended to be used to increase pool of results to compare against.
    func fixedAtSize() -> ValueAndChoiceTreeInterpreter<FinalOutput> {
        var fixed = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: context.materializePicks,
            seed: context.baseSeed,
            maxRuns: context.maxRuns
        )
        fixed.context.isFixed = true
        fixed.context.runs = context.runs
        return fixed
    }

    // MARK: - Generic Wrapper

    /// Typed entry point that erases to ``generateRecursiveAny`` and casts the result back.
    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        guard let (value, tree) = try generateRecursiveAny(
            gen.erase(), with: inputValue as Any, context: &context
        ) else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! Output, tree)
    }

    // MARK: - Recursive Engine

    /// Non-generic recursive engine operating entirely on type-erased generators and values.
    ///
    /// Walks the ``FreerMonad`` spine: `.pure` returns immediately; `.impure` dispatches the ``ReflectiveOperation`` to the appropriate handler (chooseBits, pick, sequence, filter, and so on), then feeds the result into the continuation. The `inputValue` carries the contramap input for prune/contramap operations; it is `()` at the top-level call.
    ///
    /// - Returns: The generated value paired with its choice tree, or `nil` if generation fails (for example, filter exhaustion or PRNG budget exceeded).
    static func generateRecursiveAny(
        _ gen: ReflectiveGenerator<Any>,
        with inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        switch gen {
        case let .pure(value):
            return (value, .just)

        case let .impure(operation, continuation):
            switch operation {
            // MARK: - Contramap

            case let .contramap(_, nextGen):
                return try handleContramap(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Prune

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Pick

            case let .pick(choices, branchCount):
                return try handlePick(
                    choices,
                    branchCount: branchCount,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Choosebits

            case let .chooseBits(min, max, tag, isRangeExplicit, scaling):
                return try handleChooseBits(
                    min: min,
                    max: max,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    scaling: scaling,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Sequence

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Zip

            case let .zip(generators, isOpaque):
                return try handleZip(
                    generators,
                    isOpaque: isOpaque,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Just

            case let .just(value):
                return try runContinuation(
                    result: value,
                    calleeChoiceTree: .just,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - GetSize

            case .getSize:
                let size = Self.consumeSize(&context)
                return try runContinuation(
                    result: size,
                    calleeChoiceTree: .getSize(size),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Resize

            case let .resize(newSize, gen):
                return try handleResize(
                    newSize: newSize,
                    gen: gen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Filter

            case let .filter(gen, fingerprint, filterType, predicate, tuned, sourceLocation):
                let filteredGen: ReflectiveGenerator<Any>
                if let tuned {
                    filteredGen = tuned
                } else if filterType == .rejectionSampling {
                    filteredGen = gen
                } else if let cached = context.tunedFilterCache[fingerprint] {
                    filteredGen = cached
                } else {
                    let resolved = (try? ChoiceGradientTuner<Any>.tune(gen, predicate: predicate)) ?? gen
                    context.tunedFilterCache[fingerprint] = resolved
                    filteredGen = resolved
                }

                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let (result, tree) = try Self.generateRecursiveAny(
                        filteredGen,
                        with: inputValue,
                        context: &context
                    ) else {
                        return nil
                    }

                    let passed = predicate(result)
                    if context.filterObservations[fingerprint] == nil {
                        context.filterObservations[fingerprint] = FilterObservation(sourceLocation: sourceLocation)
                    }
                    context.filterObservations[fingerprint]!.recordAttempt(passed: passed)
                    if passed {
                        return try runContinuation(
                            result: result,
                            calleeChoiceTree: tree,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context
                        )
                    }
                    attempts += 1
                }
                throw GeneratorError.sparseValidityCondition

                // MARK: - Classify

            case let .classify(gen, fingerprint, classifiers):
                return try handleClassify(
                    gen,
                    fingerprint: fingerprint,
                    classifiers: classifiers,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Transform

            case let .transform(kind, inner):
                return try handleTransform(
                    kind: kind,
                    inner: inner,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            case let .unique(gen, fingerprint, keyExtractor):
                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let (result, tree) = try Self.generateRecursiveAny(
                        gen,
                        with: inputValue,
                        context: &context
                    ) else {
                        return nil
                    }

                    let isDuplicate = ChoiceTreeHandlers.checkDuplicate(
                        result: result,
                        tree: tree,
                        fingerprint: fingerprint,
                        keyExtractor: keyExtractor,
                        context: &context
                    )

                    if !isDuplicate {
                        return try runContinuation(
                            result: result,
                            calleeChoiceTree: tree,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context
                        )
                    }
                    attempts += 1
                }
                throw GeneratorError.uniqueBudgetExhausted
            }
        }
    }

    // MARK: - Run Continuation

    @inline(__always)
    private static func runContinuation(
        result: Any,
        calleeChoiceTree: ChoiceTree,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let nextGen = try continuation(result)

        // Optimisation! Do not remove. This early return cuts 70% of the time for string generators
        if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if let (continuationResult, innerChoiceTree) = try generateRecursiveAny(
            nextGen,
            with: inputValue,
            context: &context
        ) {
            if nextGen.isPure {
                return (continuationResult, calleeChoiceTree)
            } else {
                return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
            }
        }
        return nil
    }

    @inline(__always)
    private static func handleContramap(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        guard let (result, tree) = try generateRecursiveAny(
            nextGen,
            with: inputValue,
            context: &context
        ) else {
            return nil
        }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        )
    }

    @inline(__always)
    private static func handlePrune(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let (result, tree) = try Self.generateRecursiveAny(
            nextGen,
            with: wrappedValue,
            context: &context
        ) else {
            return nil
        }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        )
    }

    @inline(__always)
    private static func handlePick(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        branchCount: UInt64,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        guard let selectedChoice = WeightedPickSelection.draw(
            from: choices,
            using: &context.prng
        ) else {
            return nil
        }
        let jumpSeed = context.prng.next()
        let fingerprint = choices[0].fingerprint

        if context.materializePicks == false {
            guard let result = try generateRecursiveAny(
                selectedChoice.generator,
                with: inputValue,
                context: &context
            ),
                let final = try runContinuation(
                    result: result.0,
                    calleeChoiceTree: result.1,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )
            else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            let tree = ChoiceTree.branch(
                fingerprint: fingerprint,
                weight: selectedChoice.weight,
                id: selectedChoice.id,
                branchCount: branchCount,
                choice: final.1
            )
            return (final.0, .group([tree.selecting()]))
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
                    choice.generator,
                    with: inputValue,
                    context: &context
                ),
                    let final = try runContinuation(
                        result: result.0,
                        calleeChoiceTree: result.1,
                        continuation: continuation,
                        inputValue: inputValue,
                        context: &context
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
            } else {
                var branchContext = context.jump(seed: jumpSeed)
                if let result = try generateRecursiveAny(
                    choice.generator,
                    with: inputValue,
                    context: &branchContext
                ),
                    let final = try runContinuation(
                        result: result.0,
                        calleeChoiceTree: result.1,
                        continuation: continuation,
                        inputValue: inputValue,
                        context: &branchContext
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
                branches.append(branch.selecting())
            } else if let branch {
                branches.append(branch)
            }
        }

        guard let value = finalValue else {
            throw GeneratorError.couldNotGenerateConcomitantChoiceTree
        }

        return (value, .group(branches))
    }

    @inline(__always)
    private static func handleChooseBits(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
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
        let choiceTree = ChoiceTree.choice(
            ChoiceValue(randomBits, tag: tag),
            .init(validRange: min ... max, isRangeExplicit: isRangeExplicit)
        )
        return try runContinuation(
            result: randomBits,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        )
    }

    @inline(__always)
    static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        SharedInterpreterHelpers.consumeSize(&context)
    }

    @inline(__always)
    private static func handleSequence(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        guard let (length, lengthTrees) = try interpretLength(
            lengthGen, context: &context
        ) else {
            return nil
        }

        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(Int(length))
        elements.reserveCapacity(Int(length))

        for _ in 0 ..< length {
            guard let (result, element) = try generateRecursiveAny(
                elementGen,
                with: inputValue,
                context: &context
            ) else {
                return nil
            }
            results.append(result)
            elements.append(element)
        }

        let choiceTree = ChoiceTree.sequence(
            length: length,
            elements: elements,
            lengthTrees.metadata
        )

        if let (result, _) = try runContinuation(
            result: results,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        ) {
            return (result, choiceTree)
        }
        return nil
    }

    @inline(__always)
    private static func handleZip(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        isOpaque: Bool,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        for gen in generators {
            guard let (result, tree) = try generateRecursiveAny(
                gen,
                with: inputValue,
                context: &context
            ) else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            results.append(result)
            choiceTrees.append(tree)
        }
        return try runContinuation(
            result: results,
            calleeChoiceTree: .group(choiceTrees, isOpaque: isOpaque),
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        )
    }

    @inline(__always)
    private static func handleResize(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        context.sizeOverride = newSize
        guard let result = try generateRecursiveAny(gen, with: inputValue, context: &context) else {
            return nil
        }
        let calleeTree = ChoiceTree.resize(newSize: newSize, choices: [result.1])
        return try runContinuation(
            result: result.0,
            calleeChoiceTree: calleeTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        )
    }

    @inline(__always)
    private static func handleTransform(
        kind: TransformKind,
        inner: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let result: Any
        let resultTree: ChoiceTree
        switch kind {
        case let .map(forward, _, _):
            guard let (innerValue, innerTree) = try generateRecursiveAny(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            result = try forward(innerValue)
            resultTree = innerTree
        case let .bind(fingerprint, forward, _, _, _):
            guard let (innerValue, innerTree) = try generateRecursiveAny(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            let boundGen = try forward(innerValue)
            let savedMaterializePicks = context.materializePicks
            context.materializePicks = false
            defer { context.materializePicks = savedMaterializePicks }
            guard let (boundValue, boundTree) = try generateRecursiveAny(
                boundGen, with: inputValue, context: &context
            ) else {
                return nil
            }
            result = boundValue
            resultTree = .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
        case let .metamorphic(transforms, _):
            let savedState = (context.prng.seed, context.prng.currentState)
            guard let (original, innerTree) = try generateRecursiveAny(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            var results: [Any] = [original]
            results.reserveCapacity(transforms.count + 1)
            for transform in transforms {
                context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                guard let (copy, _) = try generateRecursiveAny(
                    inner, with: inputValue, context: &context
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
            inputValue: inputValue,
            context: &context
        )
    }

    @inline(__always)
    private static func handleClassify(
        _ gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: (Any) throws -> ReflectiveGenerator<Any>,
        inputValue: Any,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        guard let (result, tree) = try generateRecursiveAny(
            gen,
            with: inputValue,
            context: &context
        ) else {
            return nil
        }
        var bucket = context.classifications[fingerprint, default: [:]]
        for (label, classifier) in classifiers where classifier(result) {
            bucket[label, default: []].insert(context.runs)
        }
        context.classifications[fingerprint] = bucket
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        )
    }
}
