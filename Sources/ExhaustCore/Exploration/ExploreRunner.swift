//
//  ExploreRunner.swift
//  Exhaust
//

/// Result of an exploration run.
public enum ExploreResult<Output> {
    /// A counterexample was found and reduced.
    case failure(
        counterexample: Output,
        reducedSequence: ChoiceSequence,
        original: Output,
        iteration: UInt64
    )
    /// A counterexample was found but reduction failed.
    case unreducedFailure(counterexample: Output, iteration: UInt64)
    /// All iterations passed without finding a failure.
    case passed(iterations: UInt64, poolSize: Int)
}

/// Feedback-guided exploration runner.
///
/// Combines seed-pool-based hill climbing with fresh generation to search the input space toward high-scorer regions while testing a property.
///
/// The runner uses a mandatory `scorer` function to guide hill-climbing: mutations that increase the scorer output are accepted, and the seed pool ranks by fitness.
public struct ExploreRunner<Output>: ~Copyable {
    private let gen: ReflectiveGenerator<Output>
    private let property: (Output) -> Bool
    private let samplingBudget: UInt64
    private let scorer: (Output) -> Double

    private var pool: DefaultSeedPool
    private var tracker: NoveltyTracker
    private var schedule: LogarithmicSchedule
    private var prng: Xoshiro256

    public init(
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        samplingBudget: UInt64 = 10000,
        poolCapacity: Int = 256,
        generateRatio: Double = 0.2,
        seed: UInt64? = nil,
        scorer: @escaping (Output) -> Double
    ) {
        self.gen = gen
        self.property = property
        self.samplingBudget = samplingBudget
        self.scorer = scorer
        pool = DefaultSeedPool(
            capacity: poolCapacity,
            generateRatio: generateRatio,
            useFitness: true
        )
        tracker = NoveltyTracker()
        schedule = LogarithmicSchedule()
        if let seed {
            prng = Xoshiro256(seed: seed)
        } else {
            prng = Xoshiro256()
        }
    }

    public var baseSeed: UInt64 {
        prng.seed
    }

    // MARK: - Run

    public mutating func run() -> ExploreResult<Output> {
        var iteration: UInt64 = 0

        // Phase 1: Generate an initial batch of fresh values to seed the pool
        let initialBatch = min(samplingBudget, 100)
        var interpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: prng.seed,
            maxRuns: initialBatch
        )

        while let (value, tree) = try? interpreter.next() {
            iteration += 1

            if property(value) == false {
                return reduceAndReturn(value: value, tree: tree, iteration: iteration)
            }

            let sequence = ChoiceSequence(tree)
            let novelty = tracker.score(tree: tree, sequence: sequence)
            let fitness = scorer(value)
            if novelty > 0 || fitness > 0 {
                pool.invest(Seed(
                    sequence: sequence,
                    tree: tree,
                    noveltyScore: novelty,
                    fitness: fitness,
                    generation: iteration
                ))
            }
        }

        // Phase 2: Main exploration loop
        while iteration < samplingBudget {
            let directive = pool.sample(using: &prng)

            switch directive {
            case .generate:
                // Fresh generation
                if let result = generateFreshValue(&iteration) {
                    return result
                }

            case let .mutate(seed):
                // Hill-climb the seed
                let energy = schedule.energy(
                    for: seed,
                    poolSize: pool.count,
                    averagePoolFitness: pool.averageFitness
                )

                let climbBudget = min(energy * 4, Int(samplingBudget - iteration))
                guard climbBudget > 0 else { continue }

                let result = HillClimber.climb(
                    seed: seed,
                    gen: gen,
                    scorer: scorer,
                    property: property,
                    budget: climbBudget,
                    prng: &prng
                )

                switch result {
                case let .counterexample(value, tree, probesUsed):
                    iteration += UInt64(probesUsed)
                    return reduceAndReturn(
                        value: value,
                        tree: tree,
                        iteration: iteration,
                        fromMutation: true
                    )

                case let .improved(improvedSeed, _, probesUsed):
                    iteration += UInt64(probesUsed)
                    pool.invest(improvedSeed)

                case let .unchanged(probesUsed):
                    iteration += UInt64(probesUsed)
                    pool.revise()
                }
            }
        }

        return .passed(iterations: iteration, poolSize: pool.count)
    }

    // MARK: - Helpers

    private mutating func generateFreshValue(_ iteration: inout UInt64) -> ExploreResult<Output>? {
        iteration += 1
        let runSeed = GenerationContext.runSeed(base: prng.seed, runIndex: iteration)
        var singleInterpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: runSeed,
            maxRuns: 1
        )

        guard let (value, tree) = try? singleInterpreter.next() else { return nil }

        if property(value) == false {
            return reduceAndReturn(value: value, tree: tree, iteration: iteration)
        }

        let sequence = ChoiceSequence(tree)
        let novelty = tracker.score(tree: tree, sequence: sequence)
        let fitness = scorer(value)
        if novelty > 0 || fitness > 0 {
            pool.invest(Seed(
                sequence: sequence,
                tree: tree,
                noveltyScore: novelty,
                fitness: fitness,
                generation: iteration
            ))
        }

        return nil
    }

    /// Reduce a failing value and return the result.
    ///
    /// Always reflects to get a structurally correct tree, since `materializePicks: false` trees lack unselected branches needed by reducer strategies.
    private func reduceAndReturn(
        value: Output,
        tree: ChoiceTree,
        iteration: UInt64,
        fromMutation _: Bool = false
    ) -> ExploreResult<Output> {
        do {
            let reflected = try Interpreters.reflect(gen, with: value)
            let reduceTree: ChoiceTree = if let reflected {
                reflected
            } else {
                tree
            }

            if let (reducedSequence, reducedValue) = try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: reduceTree,
                output: value,
                config: .init(maxStalls: 2),
                property: property
            ) {
                return .failure(
                    counterexample: reducedValue,
                    reducedSequence: reducedSequence,
                    original: value,
                    iteration: iteration
                )
            }
        } catch {
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_reduce_error",
                "\(error)"
            )
        }
        return .unreducedFailure(counterexample: value, iteration: iteration)
    }
}
