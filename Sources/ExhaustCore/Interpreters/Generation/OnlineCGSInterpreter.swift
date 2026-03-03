//
//  OnlineCGSInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import Foundation

// swiftlint:disable function_parameter_count

/// Online Choice Gradient Sampling interpreter that generates values directly.
///
/// Unlike the eager `GeneratorTuning` tuner (which pre-computes all pick weights
/// in a single top-down pass), this interpreter implements the paper's **online, per-value**
/// algorithm (Figure 3.3). At each `pick` encountered during generation, it computes
/// "derivatives" (residual generators after choosing each branch), samples from each
/// derivative to measure fitness, and selects based on those fitness scores.
///
/// This avoids diversity collapse on recursive generators because each derivative has
/// already fixed all choices above it, making deeper sampling tractable.
@_spi(ExhaustInternal) public struct OnlineCGSInterpreter<FinalOutput>: IteratorProtocol, Sequence {
    @_spi(ExhaustInternal) public typealias Element = FinalOutput

    /// A function that composes a local sub-generator with all outer continuations
    /// to produce a `FinalOutput`. This is the key mechanism for computing derivatives
    /// at arbitrary depth.
    typealias DerivativeWrapper = (ReflectiveGenerator<Any>) throws -> ReflectiveGenerator<FinalOutput>

    let generator: ReflectiveGenerator<FinalOutput>
    private var context: GenerationContext

    // CGS-specific fields
    private let predicate: (FinalOutput) -> Bool
    private let sampleCount: UInt64
    private var cgsState: CGSState

    private struct CGSState {
        var samplingPRNG: Xoshiro256
    }

    @_spi(ExhaustInternal) public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64 = 50,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
    ) {
        self.generator = generator
        self.predicate = predicate
        self.sampleCount = sampleCount
        let prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        var samplingPRNG = prng
        samplingPRNG.jump()
        cgsState = CGSState(samplingPRNG: samplingPRNG)
        context = .init(
            maxRuns: maxRuns ?? 100,
            baseSeed: prng.seed,
            isFixed: false,
            size: 0,
            prng: prng,
        )
    }

    // MARK: - Iterator

    @_spi(ExhaustInternal) public mutating func next() -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }

        // Per-run seed derivation: each run gets an independent PRNG
        let runSeed = GenerationContext.runSeed(base: context.baseSeed, runIndex: context.runs)
        context.prng = Xoshiro256(seed: runSeed)
        var samplingPRNG = context.prng
        samplingPRNG.jump()
        cgsState.samplingPRNG = samplingPRNG

        let wrapper: DerivativeWrapper = { $0.map { $0 as! FinalOutput } }

        defer {
            context.runs += 1
        }

        do {
            return try Self.generateRecursive(
                generator,
                with: (),
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
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
        cgsState: inout CGSState,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> Output? {
        switch gen {
        case let .pure(value):
            return value

        case let .impure(operation, continuation):
            switch operation {
            // MARK: - Contramap

            case let .contramap(_, nextGen):
                guard let result = try generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                ) else { return nil }
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Prune

            case let .prune(nextGen):
                guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
                    return nil
                }
                guard let result = try generateRecursive(
                    nextGen,
                    with: wrappedValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                ) else { return nil }
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Pick (CGS Core)

            case let .pick(choices):
                return try handlePick(
                    choices,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
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
                            cgsState: &cgsState,
                            wrapper: wrapper,
                        )
                    }
                }
                let randomBits = context.prng.next(in: min ... max)
                return try runContinuation(
                    result: randomBits,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Sequence

            case let .sequence(lengthGen, elementGen):
                guard let length = try generateRecursive(
                    lengthGen,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                ) else {
                    return nil
                }

                var results: [Any] = []
                results.reserveCapacity(Int(length))
                let didSucceed = try SequenceExecutionKernel.run(count: length) {
                    guard let result = try generateRecursive(
                        elementGen,
                        with: inputValue,
                        context: &context,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        cgsState: &cgsState,
                        wrapper: wrapper,
                        insideSubdividedChooseBits: insideSubdividedChooseBits,
                    ) else {
                        return false
                    }
                    results.append(result)
                    return true
                }
                guard didSucceed else { return nil }
                return try runContinuation(
                    result: results,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
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
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Just

            case let .just(value):
                return try runContinuation(
                    result: value,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - GetSize

            case .getSize:
                let size = context.sizeOverride ?? GenerationContext.scaledSize(forRun: context.runs)
                context.sizeOverride = nil
                return try runContinuation(
                    result: size,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Resize

            case let .resize(newSize, gen):
                context.sizeOverride = newSize
                guard let result = try generateRecursive(
                    gen,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                ) else { return nil }
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
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
                    guard let result = try generateRecursive(
                        tunedGen,
                        with: inputValue,
                        context: &context,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        cgsState: &cgsState,
                        wrapper: wrapper,
                        insideSubdividedChooseBits: insideSubdividedChooseBits,
                    ) else { return nil }

                    if filterPredicate(result) {
                        return try runContinuation(
                            result: result,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context,
                            predicate: predicate,
                            sampleCount: sampleCount,
                            cgsState: &cgsState,
                            wrapper: wrapper,
                            insideSubdividedChooseBits: insideSubdividedChooseBits,
                        )
                    }
                    attempts += 1
                }
                throw GeneratorError.sparseValidityCondition

            // MARK: - Classify

            case let .classify(gen, fingerprint, classifiers):
                guard let result = try generateRecursive(
                    gen,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                ) else { return nil }
                for (label, classifier) in classifiers where classifier(result) {
                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
                }
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    wrapper: wrapper,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                )

            // MARK: - Unique

            case let .unique(gen, fingerprint, keyExtractor):
                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let result = try generateRecursive(
                        gen,
                        with: inputValue,
                        context: &context,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        cgsState: &cgsState,
                        wrapper: wrapper,
                        insideSubdividedChooseBits: insideSubdividedChooseBits,
                    ) else { return nil }

                    let isDuplicate: Bool
                    if let keyExtractor {
                        let key = keyExtractor(result)
                        isDuplicate = !context.uniqueSeenKeys[fingerprint, default: []].insert(key).inserted
                    } else {
                        // Without a key extractor, try AnyHashable-based dedup
                        let key = result as? AnyHashable ?? AnyHashable(ObjectIdentifier(type(of: result)))
                        isDuplicate = !context.uniqueSeenKeys[fingerprint, default: []].insert(key).inserted
                    }

                    if !isDuplicate {
                        return try runContinuation(
                            result: result,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context,
                            predicate: predicate,
                            sampleCount: sampleCount,
                            cgsState: &cgsState,
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
        continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> Output? {
        let nextGen = try continuation(result)
        return try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
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
        cgsState: inout CGSState,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> Output? {
        // 1. Compute fitness for each choice via derivative sampling
        let currentSize = context.sizeOverride ?? GenerationContext.scaledSize(forRun: context.runs)
        var fitnesses = ContiguousArray<UInt64>()
        fitnesses.reserveCapacity(choices.count)

        for choice in choices {
            let derivative = try choice.generator.bind { innerValue in
                try continuation(innerValue).erase()
            }
            let fullDerivative: ReflectiveGenerator<FinalOutput> = try wrapper(derivative)

            var successCount: UInt64 = 0
            for _ in 0 ..< sampleCount {
                do {
                    let result = try LightweightSampler.sample(
                        fullDerivative,
                        using: &cgsState.samplingPRNG,
                        size: currentSize,
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

        // Consume a PRNG value to keep parity with other interpreters
        _ = context.prng.next()

        // 4. Update wrapper for the selected branch
        let branchWrapper: DerivativeWrapper = { gen in
            try wrapper(gen.bind { innerValue in
                try continuation(innerValue).erase()
            })
        }

        // 5. Recurse on selected choice's generator
        guard let result = try generateRecursive(
            selectedChoice.generator,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            wrapper: branchWrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        ) else {
            return nil
        }

        // 6. Apply continuation
        return try runContinuation(
            result: result,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
    }

    // MARK: - ChooseBits Subdivision

    /// Subdivides a `chooseBits` range into subranges, uses CGS derivative sampling
    /// to select a subrange weighted by fitness, then generates a random value within
    /// the selected subrange.
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
        cgsState: inout CGSState,
        wrapper: @escaping DerivativeWrapper,
    ) throws -> Output? {
        let rangeSize = max - min + 1
        let subrangeCount = Swift.min(4, Int(Swift.min(rangeSize, UInt64(Int.max))))
        let subranges = (min ... max).split(into: subrangeCount)
        let currentSize = context.sizeOverride ?? GenerationContext.scaledSize(forRun: context.runs)

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
            let derivative = try subGen.bind { innerValue in
                try continuation(innerValue).erase()
            }
            let fullDerivative = try wrapper(derivative)

            var successCount: UInt64 = 0
            for _ in 0 ..< sampleCount {
                do {
                    let result = try LightweightSampler.sample(
                        fullDerivative,
                        using: &cgsState.samplingPRNG,
                        size: currentSize,
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
                generator: .pure(subrange.lowerBound),
            ))
        }

        guard let selected = WeightedPickSelection.draw(from: weightedSubranges, using: &context.prng) else {
            return nil
        }
        let selectedSubrange = subranges[Int(selected.id)]

        let randomBits = context.prng.next(in: selectedSubrange)

        return try runContinuation(
            result: randomBits,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            wrapper: wrapper,
            insideSubdividedChooseBits: false,
        )
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
        cgsState: inout CGSState,
        wrapper: @escaping DerivativeWrapper,
        insideSubdividedChooseBits: Bool,
    ) throws -> Output? {
        var results = [Any]()
        results.reserveCapacity(generators.count)

        for (i, gen) in generators.enumerated() {
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

            guard let result = try generateRecursive(
                gen,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                wrapper: componentWrapper,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
            ) else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            results.append(result)
        }
        return try runContinuation(
            result: results,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            wrapper: wrapper,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
        )
    }
}
