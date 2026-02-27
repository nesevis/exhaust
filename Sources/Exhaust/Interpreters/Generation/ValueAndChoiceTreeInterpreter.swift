//
//  ValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Algorithms
import Foundation

public struct ValueAndChoiceTreeInterpreter<FinalOutput>: IteratorProtocol, Sequence {
    public typealias Element = (value: FinalOutput, tree: ChoiceTree)
    typealias RunContinuation<Output> = (Any, ChoiceTree) throws -> (Output, ChoiceTree)?

    let generator: ReflectiveGenerator<FinalOutput>
    private var context: Context

    public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
    ) {
        self.generator = generator
        context = .init(
            maxRuns: maxRuns ?? 100,
            materializePicks: materializePicks,
            isFixed: false,
            size: 0,
            runs: 0,
            prng: seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256(),
        )
    }

    // MARK: - Iterator

    public mutating func next() -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }

        defer {
            context.size += context.isFixed ? 0 : 1
            context.runs += 1
        }
        do {
            return try Self.generateRecursive(generator, with: (), context: context)
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
        let fixed = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: context.materializePicks,
            seed: context.prng.seed,
            maxRuns: context.maxRuns,
        )
        fixed.context.isFixed = true
        return fixed
    }

    // MARK: - Recursive Engine

    static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: Context,
    ) throws -> (Output, ChoiceTree)? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming
            // from .chooseBits or .chooseCharacter
            return (value, ChoiceTree.just(String(String(describing: value).prefix(50))))

        case let .impure(operation, continuation):
            // Prebake the continuation and other parameters here for ease of calling
            let runContinuation: RunContinuation = { result, calleeChoiceTree in
                let nextGen = try continuation(result)

                // Optimisation! Do not remove. This early return cuts 70% of the time for string generators
                if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
                    // Early return for a pure case originating with a choice
                    return (value, calleeChoiceTree)
                }
                if let (continuationResult, innerChoiceTree) = try generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
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

            // Ditto for recursing a generator
            let runGenerator = { (gen: ReflectiveGenerator<Any>, context: Context) in
                try Self.generateRecursive(gen, with: inputValue, context: context)
            }

            switch operation {
                    // MARK: - Contramap

            case let .contramap(_, nextGen):
                return try handleContramap(
                    nextGen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            // MARK: - Prune

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            // MARK: - Pick

            case let .pick(choices):
                return try handlePick(
                    choices,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            // MARK: - Choosebits

            case let .chooseBits(min, max, tag, isRangeExplicit):
                return try handleChooseBits(
                    min: min,
                    max: max,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    context: context,
                    runContinuation: runContinuation,
                )

            // MARK: - Sequence

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    context: context,
                    inputValue: inputValue,
                    runContinuation: runContinuation,
                )

            // MARK: - Zip

            case let .zip(generators):
                return try handleZip(
                    generators,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            // MARK: - Just

            case let .just(value):
                return try runContinuation(value, .just("\(value)"))

            // MARK: - GetSize

            case .getSize:
                let size = context.sizeOverride ?? scaledSize(context.maxRuns, context.runs)
                context.sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size, .getSize(size))

            // MARK: - Resize

            case let .resize(newSize, gen):
                return try handleResize(
                    newSize: newSize,
                    gen: gen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            // MARK: - Filter

            case let .filter(gen, fingerprint, filterType, predicate):
                // Look up or create a tuned generator for this filter.
                // The fingerprint is stable per filter site, so identical filters
                // inside a bind will share the same tuned generator.
                let filteredGen: ReflectiveGenerator<Any>
                if filterType == .reject {
                    // Pure rejection sampling; no tuning required
                    filteredGen = gen
                } else if let cached = context.tunedFilterCache[fingerprint] {
                    filteredGen = cached
                } else {
                    let tuned = try? GeneratorTuning.probeAndTune(gen, predicate: predicate)
                    filteredGen = tuned ?? gen
                    context.tunedFilterCache[fingerprint] = filteredGen
                }

                var attempts = 0 as UInt64
                while attempts < context.maxFilterRuns {
                    guard let (result, tree) = try runGenerator(filteredGen, context) else { return nil }

                    if predicate(result) {
                        return try runContinuation(result, tree)
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
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .unique(gen, fingerprint, keyExtractor):
                var attempts = 0 as UInt64
                while attempts < context.maxFilterRuns {
                    guard let (result, tree) = try runGenerator(gen, context) else { return nil }

                    let isDuplicate: Bool
                    if let keyExtractor {
                        let key = keyExtractor(result)
                        isDuplicate = !context.uniqueSeenKeys[fingerprint, default: []].insert(key).inserted
                    } else {
                        let sequence = ChoiceSequence.flatten(tree)
                        isDuplicate = !context.uniqueSeenSequences[fingerprint, default: []].insert(sequence).inserted
                    }

                    if !isDuplicate {
                        return try runContinuation(result, tree)
                    }
                    attempts += 1
                }
                throw GeneratorError.uniqueBudgetExhausted
            }
        }
    }

    @inline(__always)
    private static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        runContinuation: RunContinuation<Output>,
    ) throws -> (Output, ChoiceTree)? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try generateRecursive(nextGen, with: inputValue, context: context) },
            runContinuation: { try runContinuation($0.0, $0.1) },
        )
    }

    @inline(__always)
    private static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        runContinuation: RunContinuation<Output>,
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        return try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try Self.generateRecursive(nextGen, with: wrappedValue, context: context) },
            runContinuation: { try runContinuation($0.0, $0.1) },
        )
    }

    @inline(__always)
    private static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        inputValue: some Any,
        context: Context,
        runContinuation: RunContinuation<Output>,
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
                if let result = try generateRecursive(
                    choice.generator,
                    with: inputValue,
                    context: isSelected ? context : context.jump(seed: jumpSeed),
                ),
                    let final = try runContinuation(result.0, result.1)
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
        context: Context,
        runContinuation: RunContinuation<Output>,
    ) throws -> (Output, ChoiceTree)? {
        let randomBits = context.prng.next(in: min ... max)
        let choiceTree = ChoiceTree.choice(
            ChoiceValue(randomBits, tag: tag),
            .init(validRanges: [min ... max], isRangeExplicit: isRangeExplicit),
        )
        return try runContinuation(randomBits, choiceTree)
    }

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        context: Context,
        inputValue: some Any,
        runContinuation: RunContinuation<Output>,
    ) throws -> (Output, ChoiceTree)? {
        guard let (length, lengthTrees) = try generateRecursive(
            lengthGen,
            with: inputValue,
            context: context,
        ) else {
            return nil
        }

        var results: [Any] = []
        var elements: [ChoiceTree] = []
        results.reserveCapacity(Int(length))
        elements.reserveCapacity(Int(length))

        let didSucceed = try SequenceExecutionKernel.run(count: length) {
            guard let (result, element) = try generateRecursive(elementGen, with: inputValue, context: context) else {
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

        if let (result, _) = try runContinuation(results, choiceTree) {
            return (result, choiceTree)
        }
        return nil
    }

    @inline(__always)
    private static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        inputValue: some Any,
        context: Context,
        runContinuation: RunContinuation<Output>,
    ) throws -> (Output, ChoiceTree)? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        for gen in generators {
            guard let (result, tree) = try generateRecursive(gen, with: inputValue, context: context) else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            results.append(result)
            choiceTrees.append(tree)
        }
        return try runContinuation(results, .group(choiceTrees))
    }

    @inline(__always)
    private static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        runContinuation: RunContinuation<Output>,
    ) throws -> (Output, ChoiceTree)? {
        context.sizeOverride = newSize
        guard let result = try generateRecursive(gen, with: inputValue, context: context) else {
            return nil
        }
        return try runContinuation(result.0, .resize(newSize: newSize, choices: [result.1]))
    }

    @inline(__always)
    private static func handleClassify<Output>(
        _ gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        inputValue: some Any,
        context: Context,
        runContinuation: RunContinuation<Output>,
    ) throws -> (Output, ChoiceTree)? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try generateRecursive(gen, with: inputValue, context: context) },
            runContinuation: { result in
                for (label, classifier) in classifiers where classifier(result.0) {
                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
                }
                return try runContinuation(result.0, result.1)
            },
        )
    }

    // MARK: - Linear size scaling (1–100)

    private static func scaledSize(_ maxRuns: UInt64, _ completedRuns: UInt64) -> UInt64 {
        guard maxRuns > 1 else { return 1 }
        return 1 + completedRuns * 99 / (maxRuns - 1)
    }

    // MARK: - Context

    final class Context {
        let maxRuns: UInt64
        let materializePicks: Bool
        var isFixed: Bool
        var size: UInt64
        var runs: UInt64
        var sizeOverride: UInt64?
        let maxFilterRuns: UInt64 = 500
        // A nested dictionary containing the results of classifying the results by provided predicates and labels
        var classifications: [UInt64: [String: Set<UInt64>]] = [:]
        var prng: Xoshiro256

        /// Cache of tuned generators keyed by filter fingerprint
        var tunedFilterCache: [UInt64: ReflectiveGenerator<Any>] = [:]

        // Unique combinator state
        var uniqueSeenKeys: [UInt64: Set<AnyHashable>] = [:]
        var uniqueSeenSequences: [UInt64: Set<ChoiceSequence>] = [:]

        init(
            maxRuns: UInt64,
            materializePicks: Bool,
            isFixed: Bool,
            size: UInt64,
            runs: UInt64,
            sizeOverride: UInt64? = nil,
            classifications: [UInt64: [String: Set<UInt64>]] = [:],
            prng: Xoshiro256,
        ) {
            self.maxRuns = maxRuns
            self.materializePicks = materializePicks
            self.isFixed = isFixed
            self.size = size
            self.runs = runs
            self.sizeOverride = sizeOverride
            self.classifications = classifications
            self.prng = prng
        }

        func jump(seed: UInt64) -> Context {
            .init(maxRuns: maxRuns, materializePicks: materializePicks, isFixed: isFixed, size: size, runs: runs, prng: .init(seed: seed))
        }

        func printClassifications() {
            for (_, classifications) in classifications {
                ExhaustLog.info(
                    category: .generation,
                    event: "classifications_summary",
                )
                for (label, runs) in classifications {
                    ExhaustLog.info(
                        category: .generation,
                        event: "classification_count",
                        metadata: [
                            "label": label,
                            "count": "\(runs.count)",
                        ],
                    )
                }
            }
        }
    }
}

private extension ReflectiveGenerator {
    var isPure: Bool {
        if case .pure = self {
            return true
        }
        return false
    }
}
