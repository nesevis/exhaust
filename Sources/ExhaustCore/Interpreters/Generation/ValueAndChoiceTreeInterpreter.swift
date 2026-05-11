//
//  ValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

// MARK: - Academic Provenance

//
// Combines the dissertation's `generate` and `randomness` interpretations (Goldstein §3.3.3) into a single pass that produces both the value and the ChoiceTree recording every decision. The ChoiceTree is Exhaust's extension — the dissertation uses flat choice sequences. Correctness relies on the factoring theorem (§4.4): replaying the recorded randomness through the generator reproduces the original value.

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

        // Per-run seed derivation: each run gets an independent PRNG
        if !context.isFixed {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }

        defer {
            context.runs += 1
        }
        do {
            return try Self.generateRecursive(generator, with: (), context: &context)
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

        return try Self.generateRecursive(generator, with: (), context: &context)
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

    // MARK: - Recursive Engine

    /// Interprets a generator in the forward direction, producing a value and the corresponding ``ChoiceTree``.
    ///
    /// Walks the ``FreerMonad`` spine: `.pure` returns immediately; `.impure` dispatches the ``ReflectiveOperation`` to the appropriate handler (chooseBits, pick, sequence, filter, and so on), then feeds the result into the continuation. The `inputValue` carries the contramap input for prune/contramap operations; it is `()` at the top-level call.
    ///
    /// - Returns: The generated value paired with its choice tree, or `nil` if generation fails (for example, filter exhaustion or PRNG budget exceeded).
    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming from .chooseBits
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
                    guard let (result, tree) = try Self.generateRecursive(
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
                    guard let (result, tree) = try Self.generateRecursive(
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
    private static func runContinuation<Output>(
        result: Any,
        calleeChoiceTree: ChoiceTree,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        let nextGen = try continuation(result)

        // Optimisation! Do not remove. This early return cuts 70% of the time for string generators
        if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if let (continuationResult, innerChoiceTree) = try generateRecursive(
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

    /// Generates the inner value of a contramap operation, then feeds it through the continuation.
    ///
    /// Contramap does not produce its own choice tree node — the inner generator's tree is passed through unchanged. The `inputValue` is forwarded to the inner generator so that prune/contramap chains compose correctly.
    @inline(__always)
    private static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(
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
    private static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let (result, tree) = try Self.generateRecursive(
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
    private static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        branchCount: UInt64,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        guard let selectedChoice = WeightedPickSelection.draw(
            from: choices,
            using: &context.prng
        ) else {
            return nil
        }
        let jumpSeed = context.prng.next()
        let fingerprint = choices[0].fingerprint

        if context.materializePicks == false {
            guard let result = try generateRecursive(
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
            return (final.0, .group([.selected(tree)]))
        }

        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        var finalValue: Output?

        for choice in choices {
            let isSelected = choice.id == selectedChoice.id
            var value: Output?
            var branch: ChoiceTree?

            if isSelected {
                if let result = try generateRecursive(
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
                if let result = try generateRecursive(
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
                branches.append(.selected(branch))
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
    private static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
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

    /// Reads the active generation size in precedence order: a one-shot `.resize` override, then the persistent `context.size` baseline (set via the `sizeOverride` init arg — used by ``ChoiceTreeAnalysis`` to force size 100 so size-scaled sequences produce non-empty element subtrees during parameter extraction), then the per-run scaled size cycle.
    @inline(__always)
    private static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        if let override = context.sizeOverride {
            context.sizeOverride = nil
            return override
        }
        if context.size > 0 {
            return context.size
        }
        return GenerationContext.scaledSize(forRun: context.runs)
    }

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        guard let (length, lengthTrees) = try generateRecursive(
            lengthGen,
            with: inputValue,
            context: &context
        ) else {
            return nil
        }

        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(Int(length))
        elements.reserveCapacity(Int(length))

        for _ in 0 ..< length {
            guard let (result, element) = try generateRecursive(
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
    private static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        isOpaque: Bool,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        for gen in generators {
            guard let (result, tree) = try generateRecursive(
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
    private static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        context.sizeOverride = newSize
        guard let result = try generateRecursive(gen, with: inputValue, context: &context) else {
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
    private static func handleTransform<Output>(
        kind: TransformKind,
        inner: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        let result: Any
        let resultTree: ChoiceTree
        switch kind {
        case let .map(forward, _, _):
            guard let (innerValue, innerTree) = try generateRecursive(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            result = try forward(innerValue)
            resultTree = innerTree
        case let .bind(fingerprint, forward, _, _, _):
            guard let (innerValue, innerTree) = try generateRecursive(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            let boundGen = try forward(innerValue)
            let savedMaterializePicks = context.materializePicks
            context.materializePicks = false
            defer { context.materializePicks = savedMaterializePicks }
            guard let (boundValue, boundTree) = try generateRecursive(
                boundGen, with: inputValue, context: &context
            ) else {
                return nil
            }
            result = boundValue
            resultTree = .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree)
        case let .metamorphic(transforms, _):
            let savedState = (context.prng.seed, context.prng.currentState)
            guard let (original, innerTree) = try generateRecursive(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            var results: [Any] = [original]
            results.reserveCapacity(transforms.count + 1)
            for transform in transforms {
                context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                guard let (copy, _) = try generateRecursive(
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
    private static func handleClassify<Output>(
        _ gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(
            gen,
            with: inputValue,
            context: &context
        ) else {
            return nil
        }
        for (label, classifier) in classifiers where classifier(result) {
            if context.classifications[fingerprint] == nil {
                context.classifications[fingerprint] = [:]
            }
            if context.classifications[fingerprint]![label] == nil {
                context.classifications[fingerprint]![label] = []
            }
            context.classifications[fingerprint]![label]!.insert(context.runs)
        }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context
        )
    }
}
