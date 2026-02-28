//
//  OnlineCGSInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import Foundation

// swiftlint:disable function_parameter_count

/// Online Choice Gradient Sampling interpreter that generates values with choice trees.
///
/// Unlike the eager `GeneratorTuning` tuner (which pre-computes all pick weights
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
@_spi(ExhaustInternal) public struct OnlineCGSInterpreter<FinalOutput>: IteratorProtocol, Sequence {
    @_spi(ExhaustInternal) public typealias Element = (value: FinalOutput, tree: ChoiceTree)

    /// A function that composes a local sub-generator with all outer continuations
    /// to produce a `FinalOutput`. This is the key mechanism for computing derivatives
    /// at arbitrary depth.
    typealias DerivativeWrapper = (ReflectiveGenerator<Any>) throws -> ReflectiveGenerator<FinalOutput>

    let generator: ReflectiveGenerator<FinalOutput>
    private var context: GenerationContext

    // CGS-specific fields
    private let predicate: (FinalOutput) -> Bool
    private let sampleCount: UInt64
    private var samplingPRNG: Xoshiro256

    @_spi(ExhaustInternal) public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64 = 50,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
    ) {
        self.generator = generator
        self.predicate = predicate
        self.sampleCount = sampleCount
        self.samplingPRNG = seed.map { Xoshiro256(seed: $0 &+ 1) } ?? Xoshiro256()
        context = .init(
            maxRuns: maxRuns ?? 100,
            isFixed: false,
            size: 0,
            prng: seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256(),
            materializePicks: materializePicks,
        )
    }

    // MARK: - Iterator

    @_spi(ExhaustInternal) public mutating func next() -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }

        let wrapper: DerivativeWrapper = { $0.map { $0 as! FinalOutput } }

        defer {
            context.size += context.isFixed ? 0 : 1
            context.runs += 1
        }
        do {
            return try Self.generateRecursive(
                generator,
                with: (),
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                samplingPRNG: &samplingPRNG,
                wrapper: wrapper,
                insideSubdividedChooseBits: false,
            )
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

    // MARK: - Recursive Engine

    private static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> (Output, ChoiceTree)? {
        switch gen {
        case let .pure(value):
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
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Prune

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Pick

            case let .pick(choices):
                return try handlePick(
                    choices,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
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
                            context: &context,
                            predicate: predicate,
                            sampleCount: sampleCount,
                            samplingPRNG: &samplingPRNG,
                            wrapper: wrapper,
                        )
                    }
                }
                return try handleChooseBits(
                    min: min,
                    max: max,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Sequence

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Zip

            case let .zip(generators):
                return try handleZip(
                    generators,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Just

            case let .just(value):
                return try runContinuation(
                    result: value,
                    calleeChoiceTree: .just("\(value)"),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - GetSize

            case .getSize:
                let size = context.sizeOverride ?? GenerationContext.scaledSize(context.maxRuns, context.runs)
                context.sizeOverride = nil
                return try runContinuation(
                    result: size,
                    calleeChoiceTree: .getSize(size),
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Resize

            case let .resize(newSize, gen):
                return try handleResize(
                    newSize: newSize,
                    gen: gen,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Filter

            case let .filter(gen, fingerprint, filterType, filterPredicate):
                let tunedGen = ChoiceTreeHandlers.resolveFilterGenerator(
                    gen: gen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    predicate: filterPredicate,
                    context: &context,
                )

                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let (result, tree) = try Self.generateRecursive(
                        tunedGen,
                        with: inputValue,
                        context: &context,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        samplingPRNG: &samplingPRNG,
                        wrapper: wrapper,
                        insideSubdividedChooseBits: insideSubdividedChooseBits,
                    ) else { return nil }

                    if filterPredicate(result) {
                        return try runContinuation(
                            result: result,
                            calleeChoiceTree: tree,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context,
                            predicate: predicate,
                            sampleCount: sampleCount,
                            samplingPRNG: &samplingPRNG,
                            wrapper: wrapper,
                            insideSubdividedChooseBits: insideSubdividedChooseBits,
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
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Unique

            case let .unique(gen, fingerprint, keyExtractor):
                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let (result, tree) = try Self.generateRecursive(
                        gen,
                        with: inputValue,
                        context: &context,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        samplingPRNG: &samplingPRNG,
                        wrapper: wrapper,
                        insideSubdividedChooseBits: insideSubdividedChooseBits,
                    ) else { return nil }

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
                            predicate: predicate,
                            sampleCount: sampleCount,
                            samplingPRNG: &samplingPRNG,
                            wrapper: wrapper,
                            insideSubdividedChooseBits: insideSubdividedChooseBits,
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
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> (Output, ChoiceTree)? {
        let nextGen = try continuation(result)

        if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
            return (value, calleeChoiceTree)
        }
        if let (continuationResult, innerChoiceTree) = try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        ) {
            if nextGen.isPure {
                return (continuationResult, calleeChoiceTree)
            } else {
                return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
            }
        }
        return nil
    }

    // MARK: - Contramap

    @inline(__always)
    private static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        ) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
    }

    // MARK: - Prune

    @inline(__always)
    private static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> (Output, ChoiceTree)? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let (result, tree) = try Self.generateRecursive(
            nextGen,
            with: wrappedValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        ) else { return nil }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
    }

    // MARK: - Pick (CGS Core)

    @inline(__always)
    private static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
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
            for _ in 0 ..< sampleCount {
                do {
                    let result = try ValueInterpreter<FinalOutput>.generate(
                        fullDerivative,
                        maxRuns: 1,
                        using: &samplingPRNG,
                    )
                    if let value = result, predicate(value) {
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
                generator: choice.generator,
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
                var branchContext = isSelected ? context : context.jump(seed: jumpSeed)
                if let result = try generateRecursive(
                    choice.generator,
                    with: inputValue,
                    context: &branchContext,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    samplingPRNG: &samplingPRNG,
                    wrapper: branchWrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                ),
                    let final = try runContinuation(
                        result: result.0,
                        calleeChoiceTree: result.1,
                        continuation: continuation,
                        inputValue: inputValue,
                        context: &branchContext,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        samplingPRNG: &samplingPRNG,
                        wrapper: branchWrapper,
                        insideSubdividedChooseBits: insideSubdividedChooseBits,
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

    // MARK: - ChooseBits

    @inline(__always)
    private static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
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
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
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
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
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
                    isRangeExplicit: isRangeExplicit,
                ),
                continuation: { .pure($0) },
            )
            // Full derivative: subrange chooseBits → continuation → outer wrapper
            let derivative = try subGen.bind { innerValue in
                try continuation(innerValue).erase()
            }
            let fullDerivative = try wrapper(derivative)

            var successCount: UInt64 = 0
            for _ in 0 ..< sampleCount {
                do {
                    let result = try ValueInterpreter<FinalOutput>.generate(
                        fullDerivative,
                        maxRuns: 1,
                        using: &samplingPRNG,
                    )
                    if let value = result, predicate(value) {
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
                generator: .pure(subrange.lowerBound), // Placeholder — only weight and id matter
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
            .init(validRanges: [min ... max], isRangeExplicit: isRangeExplicit),
        )

        return try runContinuation(
            result: randomBits,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: false,
        )
    }

    // MARK: - Sequence

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> (Output, ChoiceTree)? {
        guard let (length, lengthTrees) = try generateRecursive(
            lengthGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
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
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                samplingPRNG: &samplingPRNG,
                wrapper: wrapper,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
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
            lengthTrees.metadata,
        )

        if let (result, _) = try runContinuation(
            result: results,
            calleeChoiceTree: choiceTree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        ) {
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
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
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
                        continuation: { .pure($0) },
                    )
                }
                return try wrapper(zipGen.bind { zipResult in
                    try continuation(zipResult).erase()
                })
            }

            guard let (result, tree) = try generateRecursive(
                gen,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                samplingPRNG: &samplingPRNG,
                wrapper: componentWrapper,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
            ) else {
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
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
    }

    // MARK: - Resize

    @inline(__always)
    private static func handleResize<Output>(
        newSize: UInt64,
        gen: ReflectiveGenerator<Any>,
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> (Output, ChoiceTree)? {
        context.sizeOverride = newSize
        guard let result = try generateRecursive(
            gen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        ) else {
            return nil
        }
        return try runContinuation(
            result: result.0,
            calleeChoiceTree: .resize(newSize: newSize, choices: [result.1]),
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
    }

    // MARK: - Classify

    @inline(__always)
    private static func handleClassify<Output>(
        _ gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        samplingPRNG: inout Xoshiro256,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> (Output, ChoiceTree)? {
        guard let (result, tree) = try generateRecursive(
            gen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        ) else { return nil }
        for (label, classifier) in classifiers where classifier(result) {
            context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
        }
        return try runContinuation(
            result: result,
            calleeChoiceTree: tree,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            samplingPRNG: &samplingPRNG,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
    }
}