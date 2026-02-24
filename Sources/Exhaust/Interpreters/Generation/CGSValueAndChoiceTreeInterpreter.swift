//
//  CGSValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import Foundation

/// Online Choice Gradient Sampling interpreter that generates values with choice trees.
///
/// Unlike the eager `ChoiceGradientSampling` adapter (which pre-computes all pick weights
/// in a single top-down pass), this interpreter implements the paper's **online, per-value**
/// algorithm (Figure 3.3). At each `pick` encountered during generation, it computes
/// "derivatives" (residual generators after choosing each branch), samples from each
/// derivative to measure fitness, and selects based on those fitness scores.
///
/// This avoids diversity collapse on recursive generators because each derivative has
/// already fixed all choices above it, making deeper sampling tractable.
///
/// The interpreter produces `(value, ChoiceTree)` pairs identical in structure to
/// `ValueAndChoiceTreeInterpreter`, ensuring full compatibility with shrinking and replay.
public struct CGSValueAndChoiceTreeInterpreter<FinalOutput>: IteratorProtocol, Sequence {
    public typealias Element = (value: FinalOutput, tree: ChoiceTree)
    typealias RunContinuation<Output> = (Any, ChoiceTree) throws -> (Output, ChoiceTree)?

    /// A function that composes a local sub-generator with all outer continuations
    /// to produce a `FinalOutput`. This is the key mechanism for computing derivatives
    /// at arbitrary depth.
    typealias DerivativeWrapper = (ReflectiveGenerator<Any>) throws -> ReflectiveGenerator<FinalOutput>

    let generator: ReflectiveGenerator<FinalOutput>
    private var context: Context

    public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64 = 50,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil
    ) {
        self.generator = generator
        context = .init(
            maxRuns: maxRuns ?? 100,
            materializePicks: materializePicks,
            isFixed: false,
            size: 0,
            runs: 0,
            prng: seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256(),
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: seed.map { Xoshiro256(seed: $0 &+ 1) } ?? Xoshiro256()
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
            let wrapper: DerivativeWrapper = { $0.map { $0 as! FinalOutput } }
            return try Self.generateRecursive(
                generator,
                with: (),
                context: context,
                wrapper: wrapper,
                insideSubdividedChooseBits: false
            )
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    // MARK: - Recursive Engine

    private static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool
    ) throws -> (Output, ChoiceTree)? {
        switch gen {
        case let .pure(value):
            return (value, ChoiceTree.just(String(String(describing: value).prefix(50))))

        case let .impure(operation, continuation):
            let runContinuation: RunContinuation<Output> = { result, calleeChoiceTree in
                let nextGen = try continuation(result)

                if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
                    return (value, calleeChoiceTree)
                }
                if let (continuationResult, innerChoiceTree) = try generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits
                ) {
                    if nextGen.isPure {
                        return (continuationResult, calleeChoiceTree)
                    } else {
                        return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
                    }
                }
                return nil
            }

            switch operation {
            // MARK: - Contramap

            case let .contramap(_, nextGen):
                return try handleContramap(
                    nextGen,
                    inputValue: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    runContinuation: runContinuation
                )

            // MARK: - Prune

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    inputValue: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    runContinuation: runContinuation
                )

            // MARK: - Pick

            case let .pick(choices):
                return try handlePick(
                    choices,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    runContinuation: runContinuation
                )

            // MARK: - ChooseBits

            case let .chooseBits(min, max, tag, isRangeExplicit):
                if !insideSubdividedChooseBits {
                    let rangeSize = max - min + 1
                    if rangeSize >= 1000 {
                        return try handleChooseBitsSubdivision(
                            min: min,
                            max: max,
                            tag: tag,
                            isRangeExplicit: isRangeExplicit,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: context,
                            wrapper: wrapper
                        )
                    }
                }
                return try handleChooseBits(
                    min: min,
                    max: max,
                    tag: tag,
                    context: context,
                    runContinuation: runContinuation
                )

            // MARK: - Sequence

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    context: context,
                    inputValue: inputValue,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    runContinuation: runContinuation
                )

            // MARK: - Zip

            case let .zip(generators):
                return try handleZip(
                    generators,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    runContinuation: runContinuation
                )

            // MARK: - Just

            case let .just(value):
                return try runContinuation(value, .just("\(value)"))

            // MARK: - GetSize

            case .getSize:
                let size = context.sizeOverride ?? logarithmicallyScaledSize(context.maxRuns, context.runs)
                context.sizeOverride = nil
                return try runContinuation(size, .getSize(size))

            // MARK: - Resize

            case let .resize(newSize, gen):
                return try handleResize(
                    newSize: newSize,
                    gen: gen,
                    inputValue: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    runContinuation: runContinuation
                )

            // MARK: - Filter

            case let .filter(gen, _, predicate):
                var attempts = 0 as UInt64
                let runGenerator = { (gen: ReflectiveGenerator<Any>, context: Context) in
                    try Self.generateRecursive(
                        gen,
                        with: inputValue,
                        context: context,
                        wrapper: wrapper,
                        insideSubdividedChooseBits: insideSubdividedChooseBits
                    )
                }
                while attempts < context.maxFilterRuns {
                    guard let (result, tree) = try runGenerator(gen, context) else { return nil }

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
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    runContinuation: runContinuation
                )
            }
        }
    }

    // MARK: - Contramap

    @inline(__always)
    private static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: {
                try generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits
                )
            },
            runContinuation: { try runContinuation($0.0, $0.1) }
        )
    }

    // MARK: - Prune

    @inline(__always)
    private static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        return try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: {
                try Self.generateRecursive(
                    nextGen,
                    with: wrappedValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits
                )
            },
            runContinuation: { try runContinuation($0.0, $0.1) }
        )
    }

    // MARK: - Pick (CGS Core)

    @inline(__always)
    private static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        // 1. Compute fitness for each choice via derivative sampling
        var fitnesses = ContiguousArray<UInt64>()
        fitnesses.reserveCapacity(choices.count)

        for choice in choices {
            // The full derivative: compose choice's generator through continuation and outer wrapper
            let derivative = try choice.generator.bind { innerValue in
                try continuation(innerValue).erase()
            }
            let fullDerivative: ReflectiveGenerator<FinalOutput> = try wrapper(derivative)

            // Sample N times and count predicate successes.
            // Errors during sampling (e.g., type casting failures in continuations)
            // are treated as failed samples — not propagated.
            var successCount: UInt64 = 0
            for _ in 0 ..< context.sampleCount {
                do {
                    let result = try ValueInterpreter<FinalOutput>.generate(
                        fullDerivative,
                        maxRuns: 1,
                        using: &context.samplingPRNG
                    )
                    if let value = result, context.predicate(value) {
                        successCount += 1
                    }
                } catch {
                    // Sampling failed — count as unsuccessful
                }
            }
            fitnesses.append(successCount)
        }

        // 2. Build weighted choices — if all zero, fall back to equal weights
        let allZero = fitnesses.allSatisfy { $0 == 0 }
        var weightedChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        weightedChoices.reserveCapacity(choices.count)
        for (i, choice) in choices.enumerated() {
            weightedChoices.append(ReflectiveOperation.PickTuple(
                siteID: choice.siteID,
                id: choice.id,
                weight: allZero ? 1 : fitnesses[i],
                generator: choice.generator
            ))
        }

        // 3. Select branch weighted by fitness
        guard let selectedChoice = WeightedPickSelection.draw(from: weightedChoices, using: &context.prng) else {
            return nil
        }

        // Consume a PRNG value to keep parity with ValueAndChoiceTreeInterpreter
        let jumpSeed = context.prng.next()

        // 4. Generate with CGS recursion — update wrapper for the selected branch
        let branchWrapper: DerivativeWrapper = { gen in
            try wrapper(gen.bind { innerValue in
                try continuation(innerValue).erase()
            })
        }

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
                    wrapper: branchWrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits
                ),
                    let final = try runContinuation(result.0, result.1)
                {
                    value = final.0
                    branch = ChoiceTree.branch(
                        siteID: choice.siteID,
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

        guard let value = finalValue else {
            throw GeneratorError.couldNotGenerateConcomitantChoiceTree
        }

        return (value, .group(branches))
    }

    // MARK: - ChooseBits

    @inline(__always)
    private static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        context: Context,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        let randomBits = context.prng.next(in: min ... max)
        let choiceTree = ChoiceTree.choice(ChoiceValue(randomBits, tag: tag), .init(validRanges: [min ... max]))
        return try runContinuation(randomBits, choiceTree)
    }

    // MARK: - ChooseBits Subdivision

    /// Subdivides a `chooseBits` range into subranges, uses CGS derivative sampling
    /// to select a subrange weighted by fitness, then generates a random value within
    /// the selected subrange. The choice tree produced is a normal `ChoiceTree.choice(...)`
    /// with the original full range, ensuring replay compatibility with the original generator.
    private static func handleChooseBitsSubdivision<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper
    ) throws -> (Output, ChoiceTree)? {
        let rangeSize = max - min + 1
        let subrangeCount = Swift.min(4, Int(Swift.min(rangeSize, UInt64(Int.max))))
        let subranges = (min ... max).split(into: subrangeCount)

        // Compute fitness for each subrange via derivative sampling
        var fitnesses = [UInt64]()
        fitnesses.reserveCapacity(subranges.count)

        for subrange in subranges {
            let subGen: ReflectiveGenerator<Any> = .impure(
                operation: .chooseBits(
                    min: subrange.lowerBound,
                    max: subrange.upperBound,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit
                ),
                continuation: { .pure($0) }
            )
            // Full derivative: subrange chooseBits → continuation → outer wrapper
            let derivative = try subGen.bind { innerValue in
                try continuation(innerValue).erase()
            }
            let fullDerivative = try wrapper(derivative)

            var successCount: UInt64 = 0
            for _ in 0 ..< context.sampleCount {
                do {
                    let result = try ValueInterpreter<FinalOutput>.generate(
                        fullDerivative,
                        maxRuns: 1,
                        using: &context.samplingPRNG
                    )
                    if let value = result, context.predicate(value) {
                        successCount += 1
                    }
                } catch {
                    // Sampling failed — count as unsuccessful
                }
            }
            fitnesses.append(successCount)
        }

        // Select subrange weighted by fitness (fall back to equal weights if all zero)
        let allZero = fitnesses.allSatisfy { $0 == 0 }
        var weightedSubranges = ContiguousArray<ReflectiveOperation.PickTuple>()
        weightedSubranges.reserveCapacity(subranges.count)
        for (i, subrange) in subranges.enumerated() {
            weightedSubranges.append(ReflectiveOperation.PickTuple(
                siteID: 0,
                id: UInt64(i),
                weight: allZero ? 1 : fitnesses[i],
                generator: .pure(subrange.lowerBound) // Placeholder — only weight and id matter
            ))
        }

        guard let selected = WeightedPickSelection.draw(from: weightedSubranges, using: &context.prng) else {
            return nil
        }
        let selectedSubrange = subranges[Int(selected.id)]

        // Generate a random value within the selected subrange
        let randomBits = context.prng.next(in: selectedSubrange)

        // Produce a choice tree with the ORIGINAL full range for replay compatibility
        let choiceTree = ChoiceTree.choice(
            ChoiceValue(randomBits, tag: tag),
            .init(validRanges: [min ... max])
        )

        // Run through the continuation (same as handleChooseBits)
        let runContinuation: RunContinuation<Output> = { result, calleeChoiceTree in
            let nextGen = try continuation(result)
            if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
                return (value, calleeChoiceTree)
            }
            if let (continuationResult, innerChoiceTree) = try generateRecursive(
                nextGen,
                with: inputValue,
                context: context,
                wrapper: wrapper,
                insideSubdividedChooseBits: false
            ) {
                if nextGen.isPure {
                    return (continuationResult, calleeChoiceTree)
                } else {
                    return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
                }
            }
            return nil
        }

        return try runContinuation(randomBits, choiceTree)
    }

    // MARK: - Sequence

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        context: Context,
        inputValue: some Any,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        guard let (length, lengthTrees) = try generateRecursive(
            lengthGen,
            with: inputValue,
            context: context,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits
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
                context: context,
                wrapper: wrapper,
                insideSubdividedChooseBits: insideSubdividedChooseBits
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

        if let (result, _) = try runContinuation(results, choiceTree) {
            return (result, choiceTree)
        }
        return nil
    }

    // MARK: - Zip

    @inline(__always)
    private static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees = [ChoiceTree]()
        choiceTrees.reserveCapacity(generators.count)

        for (i, gen) in generators.enumerated() {
            // Build wrapper for this component: fixes previously generated components,
            // leaves later components as-is for random sampling through the derivative.
            let previousResults = results
            let componentWrapper: DerivativeWrapper = { componentGen in
                let zipGen: ReflectiveGenerator<Any> = componentGen.bind { componentResult in
                    var gens = ContiguousArray<ReflectiveGenerator<Any>>()
                    gens.reserveCapacity(generators.count)
                    for (j, g) in generators.enumerated() {
                        if j < i {
                            gens.append(.pure(previousResults[j]))
                        } else if j == i {
                            gens.append(.pure(componentResult))
                        } else {
                            gens.append(g)
                        }
                    }
                    return ReflectiveGenerator<Any>.impure(
                        operation: .zip(gens),
                        continuation: { .pure($0) }
                    )
                }
                return try wrapper(zipGen.bind { zipResult in
                    try continuation(zipResult).erase()
                })
            }

            guard let (result, tree) = try generateRecursive(
                gen,
                with: inputValue,
                context: context,
                wrapper: componentWrapper,
                insideSubdividedChooseBits: insideSubdividedChooseBits
            ) else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            results.append(result)
            choiceTrees.append(tree)
        }
        return try runContinuation(results, .group(choiceTrees))
    }

    // MARK: - Resize

    @inline(__always)
    private static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        context.sizeOverride = newSize
        guard let result = try generateRecursive(
            gen,
            with: inputValue,
            context: context,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits
        ) else {
            return nil
        }
        return try runContinuation(result.0, .resize(newSize: newSize, choices: [result.1]))
    }

    // MARK: - Classify

    @inline(__always)
    private static func handleClassify<Output>(
        _ gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        inputValue: some Any,
        context: Context,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
        runContinuation: RunContinuation<Output>
    ) throws -> (Output, ChoiceTree)? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: {
                try generateRecursive(
                    gen,
                    with: inputValue,
                    context: context,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits
                )
            },
            runContinuation: { result in
                for (label, classifier) in classifiers where classifier(result.0) {
                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
                }
                return try runContinuation(result.0, result.1)
            }
        )
    }

    // MARK: - Quickcheck logarithmic scaling of test cases

    private static func logarithmicallyScaledSize(_ maxSize: UInt64, _ successfulTests: UInt64) -> UInt64 {
        let n = Double(successfulTests)
        return UInt64(log(n + 1) * Double(maxSize) / log(100))
    }

    // MARK: - Context

    private final class Context {
        let maxRuns: UInt64
        let materializePicks: Bool
        var isFixed: Bool
        var size: UInt64
        var runs: UInt64
        var sizeOverride: UInt64?
        let maxFilterRuns: UInt64 = 500
        var classifications: [UInt64: [String: Set<UInt64>]] = [:]
        var prng: Xoshiro256

        // CGS-specific fields
        let predicate: (FinalOutput) -> Bool
        let sampleCount: UInt64
        var samplingPRNG: Xoshiro256

        init(
            maxRuns: UInt64,
            materializePicks: Bool,
            isFixed: Bool,
            size: UInt64,
            runs: UInt64,
            sizeOverride: UInt64? = nil,
            classifications: [UInt64: [String: Set<UInt64>]] = [:],
            prng: Xoshiro256,
            predicate: @escaping (FinalOutput) -> Bool,
            sampleCount: UInt64,
            samplingPRNG: Xoshiro256
        ) {
            self.maxRuns = maxRuns
            self.materializePicks = materializePicks
            self.isFixed = isFixed
            self.size = size
            self.runs = runs
            self.sizeOverride = sizeOverride
            self.classifications = classifications
            self.prng = prng
            self.predicate = predicate
            self.sampleCount = sampleCount
            self.samplingPRNG = samplingPRNG
        }

        func jump(seed: UInt64) -> Context {
            .init(
                maxRuns: maxRuns,
                materializePicks: materializePicks,
                isFixed: isFixed,
                size: size,
                runs: runs,
                prng: .init(seed: seed),
                predicate: predicate,
                sampleCount: sampleCount,
                samplingPRNG: samplingPRNG
            )
        }

        func printClassifications() {
            for (_, classifications) in classifications {
                ExhaustLog.info(
                    category: .generation,
                    event: "classifications_summary"
                )
                for (label, runs) in classifications {
                    ExhaustLog.info(
                        category: .generation,
                        event: "classification_count",
                        metadata: [
                            "label": label,
                            "count": "\(runs.count)",
                        ]
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
