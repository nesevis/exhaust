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
public struct OnlineCGSInterpreter<FinalOutput>: ~Copyable, ExhaustIterator {
    public typealias Element = FinalOutput

    // MARK: - Derivative Context

    /// An inspectable data structure representing the composition of all outer continuations
    /// needed to produce a `FinalOutput` from a local sub-generator. Each `handlePick` or
    /// `handleZip` call pushes a frame; `apply` composes them to build a full derivative.
    ///
    /// This replaces the opaque `DerivativeWrapper` closure chain with a defunctionalized
    /// representation, matching the paper's treatment of CGS derivatives as syntactic
    /// transformations on the generator data structure (Goldstein, Ch. 3).
    public struct DerivativeContext {
        public private(set) var frames: [DerivativeFrame] = []

        public init() {}

        public var depth: Int { frames.count }

        public mutating func push(_ frame: DerivativeFrame) {
            frames.append(frame)
        }

        /// Compose all frames onto `gen` to produce a full `FinalOutput` generator.
        ///
        /// Frames are stored in push order (oldest first). `apply` iterates in reverse
        /// (newest/innermost first) to match the closure chain's nesting:
        /// `gen.bind(innerCont).bind(outerCont).map(cast)`.
        public func apply(_ gen: ReflectiveGenerator<Any>) throws -> ReflectiveGenerator<FinalOutput> {
            var current = gen
            for frame in frames.reversed() {
                switch frame {
                case let .bind(continuation):
                    current = try current.bind { try continuation($0) }

                case let .zipComponent(index, completed, allGenerators, continuation):
                    let capturedIndex = index
                    let capturedCompleted = completed
                    let capturedGenerators = allGenerators
                    current = try current.bind { componentResult -> ReflectiveGenerator<Any> in
                        var gens = ContiguousArray<ReflectiveGenerator<Any>>()
                        gens.reserveCapacity(capturedGenerators.count)
                        for (j, g) in capturedGenerators.enumerated() {
                            if j < capturedIndex {
                                gens.append(.pure(capturedCompleted[j]))
                            } else if j == capturedIndex {
                                gens.append(.pure(componentResult))
                            } else {
                                gens.append(g)
                            }
                        }
                        return ReflectiveGenerator<Any>.impure(
                            operation: .zip(gens),
                            continuation: { .pure($0) },
                        )
                    }.bind { zipResult in
                        try continuation(zipResult)
                    }

                }
            }
            return current.map { $0 as! FinalOutput }
        }
    }

    public enum DerivativeFrame {
        case bind(continuation: (Any) throws -> ReflectiveGenerator<Any>)
        case zipComponent(
            index: Int,
            completed: [Any],
            allGenerators: ContiguousArray<ReflectiveGenerator<Any>>,
            continuation: (Any) throws -> ReflectiveGenerator<Any>
        )
    }

    let generator: ReflectiveGenerator<FinalOutput>
    private var context: GenerationContext

    // CGS-specific fields
    private let predicate: (FinalOutput) -> Bool
    private let sampleCount: UInt64
    private var cgsState: CGSState

    private struct CGSState: ~Copyable {
        var samplingPRNG: Xoshiro256
        var fitnessAccumulator: FitnessAccumulator?
    }

    public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64 = 50,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
        fitnessAccumulator: FitnessAccumulator? = nil,
    ) {
        self.generator = generator
        self.predicate = predicate
        self.sampleCount = sampleCount
        let baseSeed: UInt64
        if let seed {
            baseSeed = seed
        } else {
            var rng = SystemRandomNumberGenerator()
            baseSeed = rng.next()
        }
        var samplingPRNG = Xoshiro256(seed: baseSeed)
        samplingPRNG.jump()
        cgsState = CGSState(samplingPRNG: samplingPRNG, fitnessAccumulator: fitnessAccumulator)
        context = .init(
            maxRuns: maxRuns ?? 100,
            baseSeed: baseSeed,
            isFixed: false,
            size: 0,
            prng: Xoshiro256(seed: baseSeed),
        )
    }

    // MARK: - Iterator

    public mutating func next() -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }

        // Per-run seed derivation: each run gets an independent PRNG
        let runSeed = GenerationContext.runSeed(base: context.baseSeed, runIndex: context.runs)
        context.prng = Xoshiro256(seed: runSeed)
        cgsState.samplingPRNG = Xoshiro256(seed: runSeed)
        cgsState.samplingPRNG.jump()

        let derivativeContext = DerivativeContext()

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
                derivativeContext: derivativeContext,
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
        derivativeContext: DerivativeContext,
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
                    derivativeContext: derivativeContext,
                ) else { return nil }
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
                ) else { return nil }
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
                )

            // MARK: - ChooseBits

            case let .chooseBits(min, max, tag, isRangeExplicit):
                if derivativeContext.depth < 3, max >= min {
                    let rangeSize = (max - min) &+ 1
                    if rangeSize >= 1000 {
                        // Synthesize a pick over subranges, matching GeneratorTuning.tuneChooseBits
                        let subrangeCount = Swift.min(4, Int(Swift.min(rangeSize, UInt64(Int.max))))
                        let subranges = (min ... max).split(into: subrangeCount)

                        var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
                        subrangeChoices.reserveCapacity(subranges.count)

                        for (i, subrange) in subranges.enumerated() {
                            let subGen: ReflectiveGenerator<Any> = .impure(
                                operation: .chooseBits(
                                    min: subrange.lowerBound,
                                    max: subrange.upperBound,
                                    tag: tag,
                                    isRangeExplicit: isRangeExplicit,
                                ),
                                continuation: { .pure($0) },
                            )
                            subrangeChoices.append(ReflectiveOperation.PickTuple(
                                siteID: 0,
                                id: UInt64(i),
                                weight: 1,
                                generator: subGen,
                            ))
                        }

                        let synthesisedPick: ReflectiveGenerator<Output> = .impure(
                            operation: .pick(choices: subrangeChoices),
                            continuation: continuation,
                        )

                        return try generateRecursive(
                            synthesisedPick,
                            with: inputValue,
                            context: &context,
                            predicate: predicate,
                            sampleCount: sampleCount,
                            cgsState: &cgsState,
                            derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
                ) else {
                    return nil
                }

                var results: [Any] = []
                results.reserveCapacity(Int(length))
                // Skip derivative evaluation for element-level picks: without
                // .sequenceElement frames, derivatives can't compose through the
                // sequence boundary (element values would hit the predicate with
                // wrong types). Depth >= 4 triggers handlePick's fast path.
                var elementDerivativeContext = DerivativeContext()
                for _ in 0 ..< 4 {
                    elementDerivativeContext.push(.bind(continuation: { .pure($0) }))
                }
                let didSucceed = try SequenceExecutionKernel.run(count: length) {
                    guard let result = try generateRecursive(
                        elementGen,
                        with: inputValue,
                        context: &context,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        cgsState: &cgsState,
                        derivativeContext: elementDerivativeContext,
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
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
                ) else { return nil }
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext,
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
                        derivativeContext: derivativeContext,
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
                            derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
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
                    derivativeContext: derivativeContext,
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
                        derivativeContext: derivativeContext,
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
                            derivativeContext: derivativeContext,
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
        derivativeContext: DerivativeContext,
    ) throws -> Output? {
        let nextGen = try continuation(result)
        return try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext,
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
        derivativeContext: DerivativeContext,
    ) throws -> Output? {
        // Fast path: single choice or deep pick — skip derivative evaluation.
        // Without .sequenceElement frames, derivative context cannot compose through
        // sequence boundaries, so deep picks must fall back to weighted selection.
        let effectiveSampleCount = Swift.max(2, sampleCount >> derivativeContext.depth)
        if choices.count == 1 || derivativeContext.depth >= 4 {
            guard let selectedChoice = WeightedPickSelection.draw(from: choices, using: &context.prng) else {
                return nil
            }
            _ = context.prng.next()

            var branchContext = derivativeContext
            branchContext.push(.bind(continuation: { try continuation($0).erase() }))

            guard let result = try generateRecursive(
                selectedChoice.generator,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: branchContext,
            ) else {
                return nil
            }
            return try runContinuation(
                result: result,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: derivativeContext,
            )
        }

        // 0. Vocabulary elimination: skip derivative evaluation for choices
        // that are historically dead (0 fitness after ≥30 observations).
        // Once a choice is rejected enough times, remove it from the proposal
        // distribution to avoid wasting derivative evaluations on known-dead
        // branches.
        //
        // Adapted from the adaptive rejection sampling vocabulary elimination
        // in: Lipkin et al., "Fast Controlled Generation from Language Models
        // with Adaptive Weighted Rejection Sampling", COLM 2025.
        // arXiv:2504.05410
        let currentSize = context.sizeOverride ?? GenerationContext.scaledSize(forRun: context.runs)
        let choiceCount = choices.count
        let minDeadObservations: UInt64 = 30

        var liveChoiceMap = ContiguousArray<Int>()
        liveChoiceMap.reserveCapacity(choiceCount)
        if let accumulator = cgsState.fitnessAccumulator {
            for (i, choice) in choices.enumerated() {
                let key = FitnessAccumulator.SiteChoiceKey(siteID: choice.siteID, choiceID: choice.id)
                if let record = accumulator.records[key],
                   record.observationCount >= minDeadObservations,
                   record.totalFitness == 0
                {
                    continue
                }
                liveChoiceMap.append(i)
            }
            if liveChoiceMap.isEmpty {
                liveChoiceMap = ContiguousArray(0 ..< choiceCount)
            }
        } else {
            liveChoiceMap = ContiguousArray(0 ..< choiceCount)
        }

        // Single live choice after elimination — skip derivative evaluation
        if liveChoiceMap.count == 1 {
            let selectedChoice = choices[liveChoiceMap[0]]
            _ = context.prng.next()

            var branchContext = derivativeContext
            branchContext.push(.bind(continuation: { try continuation($0).erase() }))

            guard let result = try generateRecursive(
                selectedChoice.generator,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: branchContext,
            ) else {
                return nil
            }
            return try runContinuation(
                result: result,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: derivativeContext,
            )
        }

        // 1. Compute fitness via interleaved derivative sampling
        //
        // Build derivatives only for live choices, then sample in rounds.
        // This allows adaptive stopping when the relative ranking is decided,
        // rather than exhausting the full budget per choice independently.
        var derivatives = ContiguousArray<ReflectiveGenerator<FinalOutput>>()
        derivatives.reserveCapacity(liveChoiceMap.count)
        for i in liveChoiceMap {
            let derivative = try choices[i].generator.bind { innerValue in
                try continuation(innerValue).erase()
            }
            derivatives.append(try derivativeContext.apply(derivative))
        }

        var fitnesses = ContiguousArray(repeating: UInt64(0), count: choiceCount)
        let minRounds = Swift.min(UInt64(8), effectiveSampleCount)
        var completedRounds: UInt64 = 0

        sampling: for round in 0 ..< effectiveSampleCount {
            completedRounds = round + 1
            for (derivIdx, choiceIdx) in liveChoiceMap.enumerated() {
                do {
                    let result = try LightweightSampler.sample(
                        derivatives[derivIdx],
                        using: &cgsState.samplingPRNG,
                        size: currentSize,
                    )
                    if let value = result, predicate(value) {
                        fitnesses[choiceIdx] += 1
                    }
                } catch {
                    // Sampling failed — count as unsuccessful
                }
            }

            // Adaptive stopping: check if ranking is decided after minimum rounds
            if round + 1 >= minRounds {
                var best: UInt64 = 0
                var secondBest: UInt64 = 0
                var nonZeroCount = 0
                for f in fitnesses {
                    if f > 0 { nonZeroCount += 1 }
                    if f > best {
                        secondBest = best
                        best = f
                    } else if f > secondBest {
                        secondBest = f
                    }
                }
                // All zero — keep sampling, might still find something
                guard best > 0 else { continue }
                // Only one viable choice — ranking is decided
                if nonZeroCount == 1 { break sampling }
                // Leader dominates — ranking is unlikely to change
                if best >= secondBest &* 3 { break sampling }
            }
        }

        // 1b. Record fitness data for live choices only (dead choices are
        // not evaluated and should not accumulate phantom observations)
        if let accumulator = cgsState.fitnessAccumulator {
            for choiceIdx in liveChoiceMap {
                let choice = choices[choiceIdx]
                accumulator.record(
                    siteID: choice.siteID,
                    choiceID: choice.id,
                    fitness: fitnesses[choiceIdx],
                    observations: completedRounds,
                )
            }
        }

        // 2. Build weighted choices — dead choices get weight 0,
        // live choices with all-zero fitness fall back to equal weights
        let allLiveZero = liveChoiceMap.allSatisfy { fitnesses[$0] == 0 }
        var isLive = ContiguousArray(repeating: false, count: choiceCount)
        for i in liveChoiceMap { isLive[i] = true }
        var weightedChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        weightedChoices.reserveCapacity(choices.count)
        for (i, choice) in choices.enumerated() {
            weightedChoices.append(ReflectiveOperation.PickTuple(
                siteID: choice.siteID,
                id: choice.id,
                weight: allLiveZero ? (isLive[i] ? 1 : 0) : fitnesses[i],
                generator: choice.generator,
            ))
        }

        // 3. Select branch weighted by fitness
        guard let selectedChoice = WeightedPickSelection.draw(from: weightedChoices, using: &context.prng) else {
            return nil
        }

        // Consume a PRNG value to keep parity with other interpreters
        _ = context.prng.next()

        // 4. Push frame for the selected branch's context
        var branchContext = derivativeContext
        branchContext.push(.bind(continuation: { try continuation($0).erase() }))

        // 5. Recurse on selected choice's generator
        guard let result = try generateRecursive(
            selectedChoice.generator,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: branchContext,
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
            derivativeContext: derivativeContext,
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
        derivativeContext: DerivativeContext,
    ) throws -> Output? {
        var results = [Any]()
        results.reserveCapacity(generators.count)

        for (i, gen) in generators.enumerated() {
            var componentContext = derivativeContext
            componentContext.push(.zipComponent(
                index: i,
                completed: results,
                allGenerators: generators,
                continuation: { try continuation($0).erase() },
            ))

            guard let result = try generateRecursive(
                gen,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: componentContext,
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
            derivativeContext: derivativeContext,
        )
    }

}
