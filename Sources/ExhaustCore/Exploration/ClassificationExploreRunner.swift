// MARK: - Academic Background

//
// Hamlet and Taylor (IEEE TSE 16(12), 1990) show that passive partition testing — dividing the input domain and sampling uniformly from each class — barely outperforms random testing. The advantage only appears when partitions concentrate sampling where failures are likely. Here, the user supplies the partitions as directions based on their domain knowledge, so partition quality reflects the tester's insight rather than a systematic method trying to be exhaustive. Per-direction CGS tuning then exceeds Hamlet and Taylor's condition by actively reshaping each direction's sampling distribution (see ``ChoiceGradientTuner`` and ``OnlineCGSInterpreter`` for the CGS algorithm provenance).

/// Classification-aware exploration runner that steers sampling toward each declared direction via per-direction CGS tuning.
///
/// Implements the three-stage orchestration: warm-up (untuned sampling for ordering signal), per-direction tuning passes (most-hit-first, with cross-direction classification and budget pooling), and direction-preserving reduction on failure.
///
/// The runner's per-direction hit tracking (`RunState.hits`, `warmupHits`, `tuningPassSamples`) is the exploration-level analogue of ``FitnessAccumulator``'s per-choice fitness tracking in the CGS pipeline. Both accumulate empirical outcome counts to steer generation, but at different granularities: directions (named predicate regions) versus individual pick-site branches.
package struct ClassificationExploreRunner<Output>: ~Copyable {
    private let gen: Generator<Output>
    private let property: (Output) -> Bool
    private let directions: [(name: String, predicate: (Output) -> Bool)]
    private let hitsPerDirection: Int
    private let maxAttemptsPerDirection: Int
    private let regressionSeeds: [UInt64]
    private var prng: Xoshiro256

    /// Creates a runner with the given generator, property, directions, budget parameters, optional fixed seed, and regression seeds to replay after tuning.
    package init(
        gen: Generator<Output>,
        property: @escaping (Output) -> Bool,
        directions: [(name: String, predicate: (Output) -> Bool)],
        hitsPerDirection: Int,
        maxAttemptsPerDirection: Int,
        seed: UInt64? = nil,
        regressionSeeds: [UInt64] = []
    ) {
        self.gen = gen
        self.property = property
        self.directions = directions
        self.hitsPerDirection = hitsPerDirection
        self.maxAttemptsPerDirection = maxAttemptsPerDirection
        self.regressionSeeds = regressionSeeds
        if let seed {
            prng = Xoshiro256(seed: seed)
        } else {
            prng = Xoshiro256()
        }
    }

    /// The PRNG seed used for this run.
    package var baseSeed: UInt64 {
        prng.seed
    }

    // MARK: - Mutable run state

    private struct RunState {
        var coOccurrence: CoOccurrenceMatrix
        var hits: [Int]
        var warmupHits: [Int]
        var tuningPassSamples: [Int]
        var tuningPassPasses: [Int]
        var tuningPassFailures: [Int]
        var propertyInvocations: Int = 0
        var warmupSamplesDrawn: Int = 0
        var remainingPool: Int

        init(directionCount: Int, totalPool: Int) {
            coOccurrence = CoOccurrenceMatrix(directionCount: directionCount)
            hits = Array(repeating: 0, count: directionCount)
            warmupHits = Array(repeating: 0, count: directionCount)
            tuningPassSamples = Array(repeating: 0, count: directionCount)
            tuningPassPasses = Array(repeating: 0, count: directionCount)
            tuningPassFailures = Array(repeating: 0, count: directionCount)
            remainingPool = totalPool
        }
    }

    // MARK: - Run

    /// Runs the classification-aware exploration and returns a result describing per-direction coverage, co-occurrence, and any counterexample.
    package mutating func run() throws -> ClassificationExploreResult<Output> {
        let directionCount = directions.count
        let runStopwatch = Stopwatch()
        let totalPool = directionCount * maxAttemptsPerDirection
        var state = RunState(directionCount: directionCount, totalPool: totalPool)

        // MARK: Warm-up

        // Warm-up uses a fixed budget and does not draw from the per-direction tuning pool.
        let warmupBudget = 100
        var interpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: prng.seed,
            maxRuns: UInt64(warmupBudget)
        )

        while let value = try interpreter.nextValueOnly() {
            state.warmupSamplesDrawn += 1
            state.propertyInvocations += 1

            let matching = classify(value)
            state.coOccurrence.recordSample(matchingDirections: matching)

            for directionIndex in matching {
                state.hits[directionIndex] += 1
                state.warmupHits[directionIndex] += 1
            }

            if property(value) == false {
                let tree = try interpreter.reproduceFailureTree()
                let reduced = reduce(value: value, tree: tree, matchingDirections: matching)
                let reducedDirections = classify(reduced.counterexample)
                return assembleResult(
                    state: state, failure: reduced, matchingDirections: reducedDirections,
                    stopwatch: runStopwatch, termination: .propertyFailed
                )
            }
        }

        // MARK: Direction ordering

        var coveredDirections = Set<Int>()
        for directionIndex in 0 ..< directionCount where state.hits[directionIndex] >= hitsPerDirection {
            coveredDirections.insert(directionIndex)
        }

        // MARK: CGS tuning and regression seeds

        var tunedGenerators: [Int: Generator<Output>] = [:]

        if regressionSeeds.isEmpty == false {
            for directionIndex in 0 ..< directionCount where coveredDirections.contains(directionIndex) == false {
                if let tunedGen = tuneDirection(directionIndex) {
                    tunedGenerators[directionIndex] = tunedGen
                }
            }

            if let regressionFailure = try runRegressionPhase(
                tunedGenerators: tunedGenerators,
                state: &state,
                stopwatch: runStopwatch
            ) {
                return regressionFailure
            }
        }

        // MARK: Per-direction sampling passes

        while coveredDirections.count < directionCount, state.remainingPool > 0 {
            let nextDirection = (0 ..< directionCount)
                .filter { coveredDirections.contains($0) == false }
                .max(by: { state.hits[$0] < state.hits[$1] })

            guard let targetDirection = nextDirection else { break }

            let passBudget = min(maxAttemptsPerDirection, state.remainingPool)
            guard passBudget > 0 else { break }

            let tunedGen: Generator<Output>
            if let existing = tunedGenerators[targetDirection] {
                tunedGen = existing
            } else if let freshlyTuned = tuneDirection(targetDirection) {
                tunedGen = freshlyTuned
                tunedGenerators[targetDirection] = freshlyTuned
            } else {
                coveredDirections.insert(targetDirection)
                continue
            }

            if let failureResult = try sampleTunedDirection(
                tunedGen: tunedGen,
                targetDirection: targetDirection,
                passBudget: passBudget,
                directionCount: directionCount,
                state: &state,
                stopwatch: runStopwatch
            ) {
                return failureResult
            }

            coveredDirections.insert(targetDirection)
            for directionIndex in 0 ..< directionCount where coveredDirections.contains(directionIndex) == false {
                if state.hits[directionIndex] >= hitsPerDirection {
                    coveredDirections.insert(directionIndex)
                }
            }
        }

        // MARK: Final result

        let allCovered = (0 ..< directionCount).allSatisfy { state.hits[$0] >= hitsPerDirection }
        let termination: ClassificationExploreTermination = allCovered ? .coverageAchieved : .budgetExhausted

        return assembleResult(
            state: state, failure: nil, matchingDirections: [],
            stopwatch: runStopwatch, termination: termination
        )
    }

    // MARK: - CGS tuning

    private mutating func tuneDirection(_ directionIndex: Int) -> Generator<Output>? {
        let directionName = directions[directionIndex].name
        do {
            return try ChoiceGradientTuner.tune(
                gen,
                predicate: directions[directionIndex].predicate,
                warmupRuns: 400,
                sampleCount: 20,
                seed: Xoshiro256.deriveSeed(from: prng.seed, at: UInt64(directionIndex)),
                subdivisionThresholds: .relaxed
            )
        } catch {
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_tune_error",
                "direction=\(directionName) error=\(error)"
            )
            return nil
        }
    }

    // MARK: - Regression seeds

    private mutating func runRegressionPhase(
        tunedGenerators: [Int: Generator<Output>],
        state: inout RunState,
        stopwatch: Stopwatch
    ) throws -> ClassificationExploreResult<Output>? {
        for regressionSeed in regressionSeeds {
            for (directionIndex, tunedGen) in tunedGenerators.sorted(by: { $0.key < $1.key }) {
                var regressionInterpreter = ValueAndChoiceTreeInterpreter(
                    tunedGen,
                    materializePicks: false,
                    seed: regressionSeed,
                    maxRuns: 1
                )
                guard let (value, tunedTree) = try regressionInterpreter.next() else { continue }
                state.propertyInvocations += 1

                let matching = classify(value)
                state.coOccurrence.recordSample(matchingDirections: matching)
                for matchedIndex in matching {
                    state.hits[matchedIndex] += 1
                }

                if property(value) == false {
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "explore_regression_failed",
                        metadata: [
                            "seed": "\(regressionSeed)",
                            "direction": directions[directionIndex].name,
                        ]
                    )
                    let reduced = reduceFromTunedTree(value: value, tunedTree: tunedTree, matchingDirections: matching)
                    let reducedDirections = classify(reduced.counterexample)
                    return assembleResult(
                        state: state, failure: reduced, matchingDirections: reducedDirections,
                        stopwatch: stopwatch, termination: .propertyFailed
                    )
                }
            }
        }
        return nil
    }

    // MARK: - Per-direction sampling

    private mutating func sampleTunedDirection(
        tunedGen: Generator<Output>,
        targetDirection: Int,
        passBudget: Int,
        directionCount: Int,
        state: inout RunState,
        stopwatch: Stopwatch
    ) throws -> ClassificationExploreResult<Output>? {
        var passSamplesDrawn = 0
        var passInterpreter = ValueAndChoiceTreeInterpreter(
            tunedGen,
            materializePicks: false,
            seed: Xoshiro256.deriveSeed(from: prng.seed, at: UInt64(directionCount + targetDirection)),
            maxRuns: UInt64(passBudget)
        )

        while passSamplesDrawn < passBudget,
              state.hits[targetDirection] < hitsPerDirection,
              let value = try passInterpreter.nextValueOnly()
        {
            passSamplesDrawn += 1
            state.remainingPool -= 1
            state.propertyInvocations += 1
            state.tuningPassSamples[targetDirection] += 1

            let matching = classify(value)
            state.coOccurrence.recordSample(matchingDirections: matching)

            for directionIndex in matching {
                state.hits[directionIndex] += 1
            }

            let propertyHolds = property(value)
            if matching.contains(targetDirection) {
                if propertyHolds {
                    state.tuningPassPasses[targetDirection] += 1
                } else {
                    state.tuningPassFailures[targetDirection] += 1
                }
            }

            if propertyHolds == false {
                let tunedTree = try passInterpreter.reproduceFailureTree()
                let reduced = reduceFromTunedTree(value: value, tunedTree: tunedTree, matchingDirections: matching)
                let reducedDirections = classify(reduced.counterexample)
                return assembleResult(
                    state: state, failure: reduced, matchingDirections: reducedDirections,
                    stopwatch: stopwatch, termination: .propertyFailed
                )
            }
        }

        return nil
    }

    // MARK: - Rematerialization

    private func reduceFromTunedTree(
        value: Output,
        tunedTree: ChoiceTree,
        matchingDirections: [Int]
    ) -> ReducedFailure<Output> {
        let fullTree = Materializer.materialize(
            gen,
            prefix: ChoiceSequence.flatten(tunedTree),
            mode: .exact,
            fallbackTree: tunedTree,
            materializePicks: true
        )
        let reductionTree: ChoiceTree? = switch fullTree {
            case let .success(_, rematerialized, _): rematerialized
            case .rejected, .failed: nil
        }
        return reduce(value: value, tree: reductionTree, matchingDirections: matchingDirections)
    }

    // MARK: - Classification

    private func classify(_ value: Output) -> [Int] {
        var matching = [Int]()
        for index in 0 ..< directions.count where directions[index].predicate(value) {
            matching.append(index)
        }
        return matching
    }

    // MARK: - Reduction

    private func reduce(
        value: Output,
        tree: ChoiceTree?,
        matchingDirections: [Int]
    ) -> ReducedFailure<Output> {
        guard let reduceTree = tree else {
            return ReducedFailure(counterexample: value, original: value, reducedSequence: nil)
        }

        let reductionPredicate: (Output) -> Bool = matchingDirections.isEmpty
            ? { [property] output in
                property(output) == false
            }
            : { [property, directions] output in
                for directionIndex in matchingDirections where directions[directionIndex].predicate(output) == false {
                    return false
                }
                return property(output) == false
            }

        do {
            let outcome = try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: reduceTree,
                output: value,
                config: .init(maxStalls: 2),
                property: { reductionPredicate($0) == false }
            )
            if case let .reduced(reducedSequence, reducedValue) = outcome {
                return ReducedFailure(
                    counterexample: reducedValue,
                    original: value,
                    reducedSequence: reducedSequence
                )
            }
        } catch {
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_reduce_error",
                "\(error)"
            )
        }

        return ReducedFailure(counterexample: value, original: value, reducedSequence: nil)
    }

    // MARK: - Result assembly

    private func assembleResult(
        state: RunState,
        failure: ReducedFailure<Output>?,
        matchingDirections: [Int],
        stopwatch: Stopwatch,
        termination: ClassificationExploreTermination
    ) -> ClassificationExploreResult<Output> {
        var coverageEntries = [ClassificationExploreResult<Output>.DirectionCoverageEntry]()
        for (index, direction) in directions.enumerated() {
            let hits = state.hits[index]
            let warmupHits = state.warmupHits[index]
            let tuningPassPasses = state.tuningPassPasses[index]

            coverageEntries.append(.init(
                name: direction.name,
                hits: hits,
                tuningPassSamples: state.tuningPassSamples[index],
                tuningPassPasses: tuningPassPasses,
                tuningPassFailures: state.tuningPassFailures[index],
                warmupHits: warmupHits,
                isCovered: hits >= hitsPerDirection,
                warmupRuleOfThreeBound: warmupHits > 0 ? 3.0 / Double(warmupHits) : nil,
                tuningPassRuleOfThreeBound: tuningPassPasses > 0 ? 3.0 / Double(tuningPassPasses) : nil
            ))
        }

        let elapsed = stopwatch.elapsedMilliseconds

        return ClassificationExploreResult(
            counterexample: failure?.counterexample,
            original: failure?.original,
            reducedSequence: failure?.reducedSequence,
            counterexampleDirections: matchingDirections,
            directionCoverage: coverageEntries,
            coOccurrence: state.coOccurrence,
            propertyInvocations: state.propertyInvocations,
            warmupSamples: state.warmupSamplesDrawn,
            totalMilliseconds: elapsed,
            termination: termination,
            seed: prng.seed
        )
    }
}

// MARK: - Supporting types

private struct ReducedFailure<Output> {
    var counterexample: Output
    var original: Output
    var reducedSequence: ChoiceSequence?
}

/// Result of a classification-aware exploration run.
package struct ClassificationExploreResult<Output> {
    package let counterexample: Output?
    package let original: Output?
    package let reducedSequence: ChoiceSequence?
    package let counterexampleDirections: [Int]
    package let directionCoverage: [DirectionCoverageEntry]
    package let coOccurrence: CoOccurrenceMatrix
    package let propertyInvocations: Int
    package let warmupSamples: Int
    package let totalMilliseconds: Double
    package let termination: ClassificationExploreTermination
    package let seed: UInt64

    package init(
        counterexample: Output?,
        original: Output?,
        reducedSequence: ChoiceSequence?,
        counterexampleDirections: [Int],
        directionCoverage: [DirectionCoverageEntry],
        coOccurrence: CoOccurrenceMatrix,
        propertyInvocations: Int,
        warmupSamples: Int,
        totalMilliseconds: Double,
        termination: ClassificationExploreTermination,
        seed: UInt64
    ) {
        self.counterexample = counterexample
        self.original = original
        self.reducedSequence = reducedSequence
        self.counterexampleDirections = counterexampleDirections
        self.directionCoverage = directionCoverage
        self.coOccurrence = coOccurrence
        self.propertyInvocations = propertyInvocations
        self.warmupSamples = warmupSamples
        self.totalMilliseconds = totalMilliseconds
        self.termination = termination
        self.seed = seed
    }

    /// Records the coverage outcome for a single direction: hit count, sample count, and rule-of-three upper bounds for both the warm-up and tuning phases.
    package struct DirectionCoverageEntry {
        package let name: String
        package let hits: Int
        package let tuningPassSamples: Int
        package let tuningPassPasses: Int
        package let tuningPassFailures: Int
        package let warmupHits: Int
        package let isCovered: Bool
        package let warmupRuleOfThreeBound: Double?
        package let tuningPassRuleOfThreeBound: Double?

        package init(
            name: String,
            hits: Int,
            tuningPassSamples: Int,
            tuningPassPasses: Int,
            tuningPassFailures: Int,
            warmupHits: Int,
            isCovered: Bool,
            warmupRuleOfThreeBound: Double?,
            tuningPassRuleOfThreeBound: Double?
        ) {
            self.name = name
            self.hits = hits
            self.tuningPassSamples = tuningPassSamples
            self.tuningPassPasses = tuningPassPasses
            self.tuningPassFailures = tuningPassFailures
            self.warmupHits = warmupHits
            self.isCovered = isCovered
            self.warmupRuleOfThreeBound = warmupRuleOfThreeBound
            self.tuningPassRuleOfThreeBound = tuningPassRuleOfThreeBound
        }
    }
}

/// How a classification-aware exploration run terminated.
package enum ClassificationExploreTermination {
    /// Terminated because a property violation was found and reduced.
    case propertyFailed
    /// Terminated because all requested directions were hit at least once.
    case coverageAchieved
    /// Terminated because the total sample budget was exhausted before achieving full coverage.
    case budgetExhausted
}
