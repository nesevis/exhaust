//
//  ValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Foundation

// swiftlint:disable function_parameter_count

// MARK: - Academic Provenance

// Combines the `generate` and `randomness` interpretations: G⟦·⟧ + R⟦·⟧ (Goldstein §3.3.3).
// Captures a hierarchical ChoiceTree (Exhaust extension) alongside the generated value. Relates to the factoring theorem (Theorem 1, §4.4): P⟦g⟧ <$> R⟦g⟧ ≡ G⟦g⟧.

public struct ValueAndChoiceTreeInterpreter<FinalOutput>: ~Copyable, ExhaustIterator {
    public typealias Element = (value: FinalOutput, tree: ChoiceTree)

    let generator: ReflectiveGenerator<FinalOutput>
    private(set) var context: GenerationContext

    public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil
    ) {
        self.generator = generator
        let prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        context = .init(
            maxRuns: maxRuns ?? 100,
            baseSeed: prng.seed,
            isFixed: false,
            size: 0,
            prng: prng,
            materializePicks: materializePicks
        )
    }

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
            let runSeed = GenerationContext.runSeed(base: context.baseSeed, runIndex: context.runs)
            context.prng = Xoshiro256(seed: runSeed)
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

    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming
            // from .chooseBits
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

            case let .pick(choices):
                return try handlePick(
                    choices,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context
                )

            // MARK: - Choosebits

            case let .chooseBits(min, max, tag, isRangeExplicit):
                return try handleChooseBits(
                    min: min,
                    max: max,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
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
                let size =
                    context.sizeOverride
                        ?? GenerationContext.scaledSize(forRun: context.runs)
                context.sizeOverride = nil // getSize consumes the `sizeOverride`
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

            case let .filter(gen, fingerprint, filterType, predicate):
                let filteredGen = ChoiceTreeHandlers.resolveFilterGenerator(
                    gen: gen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    predicate: predicate,
                    context: &context
                )

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
                    context.filterObservations[fingerprint, default: FilterObservation()]
                        .recordAttempt(passed: passed)
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
            // Early return for a pure case originating with a choice
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
                // A large part of the trace is adding these arrays together. Chain?
                return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
            }
        }
        return nil
    }

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
        // This may or may not be used, but we always have to consume it.
        let jumpSeed = context.prng.next()

        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        var finalValue: Output?
        let branchIDs = choices.map(\.id)
        let augmentedSiteID = choices[0].siteID &+ context.pickDepth
        let savedPickDepth = context.pickDepth
        context.pickDepth += 1

        for choice in choices {
            let isSelected = choice.id == selectedChoice.id
            var value: Output?
            var branch: ChoiceTree?

            if isSelected {
                // Use context directly for the selected branch (no copy needed)
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
                        siteID: augmentedSiteID,
                        weight: choice.weight,
                        id: choice.id,
                        branchIDs: branchIDs,
                        choice: final.1
                    )
                }
            } else if context.materializePicks {
                // Use jumped context for non-selected branches
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
                        siteID: augmentedSiteID,
                        weight: choice.weight,
                        id: choice.id,
                        branchIDs: branchIDs,
                        choice: final.1
                    )
                }
            }

            if isSelected, let branch {
                finalValue = value
                branches.append(.selected(branch))
                if context.materializePicks == false {
                    break
                }
            } else if let branch {
                branches.append(branch)
            }
        }

        context.pickDepth = savedPickDepth

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
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext
    ) throws -> (Output, ChoiceTree)? {
        let randomBits = context.prng.next(in: min ... max)
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

        let didSucceed = try SequenceExecutionKernel.run(count: length) {
            guard let (result, element) = try generateRecursive(
                elementGen,
                with: inputValue,
                context: &context
            ) else {
                return false
            }
            results.append(result)
            elements.append(element)
            return true
        }
        guard didSucceed else {
            return nil
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
        return try runContinuation(
            result: result.0,
            calleeChoiceTree: .resize(newSize: newSize, choices: [result.1]),
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
        guard let (innerValue, innerTree) = try generateRecursive(
            inner,
            with: inputValue,
            context: &context
        ) else {
            return nil
        }
        let result: Any
        var resultTree = innerTree
        switch kind {
        case let .map(forward, _, _):
            result = try forward(innerValue)
        case let .bind(forward, _, _, _):
            let boundGen = try forward(innerValue)
            let savedMaterializePicks = context.materializePicks
            context.materializePicks = false
            defer { context.materializePicks = savedMaterializePicks }
            guard let (boundValue, boundTree) = try generateRecursive(
                boundGen,
                with: inputValue,
                context: &context
            ) else {
                return nil
            }
            result = boundValue
            resultTree = .bind(inner: innerTree, bound: boundTree)
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
            context.classifications[fingerprint, default: [:]][label, default: []]
                .insert(context.runs)
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
