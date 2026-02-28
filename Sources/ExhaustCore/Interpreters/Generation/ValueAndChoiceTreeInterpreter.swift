//
//  ValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Foundation

// swiftlint:disable function_parameter_count

@_spi(ExhaustInternal) public struct ValueAndChoiceTreeInterpreter<FinalOutput>: IteratorProtocol, Sequence {
    @_spi(ExhaustInternal) public typealias Element = (value: FinalOutput, tree: ChoiceTree)

    let generator: ReflectiveGenerator<FinalOutput>
    private(set) var context: GenerationContext

    @_spi(ExhaustInternal) public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
    ) {
        self.generator = generator
        let prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        context = .init(
            maxRuns: maxRuns ?? 100,
            baseSeed: prng.seed,
            isFixed: false,
            size: 0,
            prng: prng,
            materializePicks: materializePicks,
        )
    }

    @_spi(ExhaustInternal) public var baseSeed: UInt64 {
        context.baseSeed
    }

    // MARK: - Iterator

    @_spi(ExhaustInternal) public mutating func next() -> Element? {
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
                ],
            )
            context.runs = context.maxRuns
            return nil
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    /// Used to generate results around a similar level of complexity.
    /// Intended to be used to increase pool of results to compare against
    func fixedAtSize() -> ValueAndChoiceTreeInterpreter<FinalOutput> {
        var fixed = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: context.materializePicks,
            seed: context.baseSeed,
            maxRuns: context.maxRuns,
        )
        fixed.context.isFixed = true
        fixed.context.runs = context.runs
        return fixed
    }

    // MARK: - Recursive Engine

    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming
            // from .chooseBits or .chooseCharacter
            return (value, ChoiceTree.just(String(String(describing: value).prefix(50))))

        case let .impure(operation, continuation):
            switch operation {
                    // MARK: - Contramap

            case let .contramap(_, nextGen):
                return try handleContramap(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            // MARK: - Prune

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            // MARK: - Pick

            case let .pick(choices):
                return try handlePick(
                    choices,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
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
                    context: &context,
                )

            // MARK: - Sequence

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            // MARK: - Zip

            case let .zip(generators):
                return try handleZip(
                    generators,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            // MARK: - Just

            case let .just(value):
                return try runContinuation(
                    result: value,
                    calleeChoiceTree: .just("\(value)"),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            // MARK: - GetSize

            case .getSize:
                let size = context.sizeOverride ?? GenerationContext.scaledSize(forRun: context.runs)
                context.sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(
                    result: size,
                    calleeChoiceTree: .getSize(size),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            // MARK: - Resize

            case let .resize(newSize, gen):
                return try handleResize(
                    newSize: newSize,
                    gen: gen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                )

            // MARK: - Filter

            case let .filter(gen, fingerprint, filterType, predicate):
                let filteredGen = ChoiceTreeHandlers.resolveFilterGenerator(
                    gen: gen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    predicate: predicate,
                    context: &context,
                )

                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let (result, tree) = try Self.generateRecursive(filteredGen, with: inputValue, context: &context) else { return nil }

                    if predicate(result) {
                        return try runContinuation(
                            result: result,
                            calleeChoiceTree: tree,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context,
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
                    context: &context,
                )

            case let .unique(gen, fingerprint, keyExtractor):
                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let (result, tree) = try Self.generateRecursive(gen, with: inputValue, context: &context) else { return nil }

                    let isDuplicate = ChoiceTreeHandlers.checkDuplicate(
                        result: result,
                        tree: tree,
                        fingerprint: fingerprint,
                        keyExtractor: keyExtractor,
                        context: &context,
                    )

                    if !isDuplicate {
                        return try runContinuation(
                            result: result,
                            calleeChoiceTree: tree,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context,
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
        context: inout GenerationContext,
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
            context: &context,
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
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(nextGen, with: inputValue, context: &context) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    private static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let (result, tree) = try Self.generateRecursive(nextGen, with: wrappedValue, context: &context) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    private static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        guard let selectedChoice = WeightedPickSelection.draw(from: choices, using: &context.prng) else {
            return nil
        }
        // This may or may not be used, but we always have to consume it.
        let jumpSeed = context.prng.next()

        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        var finalValue: Output?
        let branchIDs = choices.map(\.id)

        for choice in choices {
            let isSelected = choice.id == selectedChoice.id
            var value: Output?
            var branch: ChoiceTree?

            if isSelected || context.materializePicks {
                var branchContext = isSelected ? context : context.jump(seed: jumpSeed)
                if let result = try generateRecursive(
                    choice.generator,
                    with: inputValue,
                    context: &branchContext,
                ),
                    let final = try runContinuation(
                        result: result.0,
                        calleeChoiceTree: result.1,
                        continuation: continuation,
                        inputValue: inputValue,
                        context: &branchContext,
                    )
                {
                    value = final.0
                    branch = ChoiceTree.branch(
                        siteID: choice.siteID,
                        weight: choice.weight,
                        id: choice.id,
                        branchIDs: branchIDs,
                        choice: final.1,
                    )
                }
                if isSelected {
                    context = branchContext
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
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        let randomBits = context.prng.next(in: min ... max)
        let choiceTree = ChoiceTree.choice(
            ChoiceValue(randomBits, tag: tag),
            .init(validRanges: [min ... max], isRangeExplicit: isRangeExplicit),
        )
        return try runContinuation(
            result: randomBits,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        guard let (length, lengthTrees) = try generateRecursive(
            lengthGen,
            with: inputValue,
            context: &context,
        ) else {
            return nil
        }

        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(Int(length))
        elements.reserveCapacity(Int(length))

        let didSucceed = try SequenceExecutionKernel.run(count: length) {
            guard let (result, element) = try generateRecursive(elementGen, with: inputValue, context: &context) else {
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
            lengthTrees.metadata,
        )

        if let (result, _) = try runContinuation(
            result: results,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        ) {
            return (result, choiceTree)
        }
        return nil
    }

    @inline(__always)
    private static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        for gen in generators {
            guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context) else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            results.append(result)
            choiceTrees.append(tree)
        }
        return try runContinuation(
            result: results,
            calleeChoiceTree: .group(choiceTrees),
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }

    @inline(__always)
    private static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
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
            context: &context,
        )
    }

    @inline(__always)
    private static func handleClassify<Output>(
        _ gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: &context) else { return nil }
        for (label, classifier) in classifiers where classifier(result) {
            context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
        }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
        )
    }
}
