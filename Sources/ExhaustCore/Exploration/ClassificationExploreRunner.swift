import Foundation

// MARK: - Academic Provenance
//
// The design synthesizes three traditions. Ostrand and Balcer's Category-Partition Method (CACM 1988) introduced systematic partitioning of the input space into named categories and choices; each direction here corresponds to one of their category–choice pairs. Claessen and Hughes's QuickCheck classify/cover (ICFP 2000) added post-hoc distribution reporting over random samples but cannot steer the sampler — coverage is observed, not guaranteed. This runner closes the gap: per-direction CGS tuning produces a stratum-specific distribution for each direction, guaranteeing K hits per stratum rather than reporting whatever the generator happened to produce.
//
// The detection-probability advantage of partition-style testing under rate uncertainty is an instance of Gutjahr's theorem (IEEE TSE 25(5), 1999), the testing-adapted analogue of Cochran's variance-reduction bound from survey sampling. Rule-of-three bounds on per-direction failure rates follow Hanley and Lippman-Hand (JAMA 249(13), 1983). CGS tuning uses the online derivative-sampling algorithm from Goldstein (Ch. 3, Fig 3.3) with offline weight baking from Tjoa et al. (OOPSLA2, 2025).
//
// Direction-preserving reduction composes cleanly with the choice-sequence reducer because the reducer is greedy under shortlex order against an arbitrary predicate — no `valid t ==>` guards that weaken shrinks (contrast Hughes, "How to Specify It!", TFP 2019).

/// Classification-aware exploration runner that steers sampling toward each declared direction via per-direction CGS tuning.
///
/// Implements the three-stage orchestration: warm-up (untuned sampling for ordering signal), per-direction tuning passes (most-hit-first, with cross-direction classification and budget pooling), and direction-preserving reduction on failure.
package struct ClassificationExploreRunner<Output>: ~Copyable {
    private let gen: ReflectiveGenerator<Output>
    private let property: (Output) -> Bool
    private let directions: [(name: String, predicate: (Output) -> Bool)]
    private let hitsPerDirection: Int
    private let maxAttemptsPerDirection: Int
    private var prng: Xoshiro256

    /// Creates a runner with the given generator, property, directions, budget parameters, and optional fixed seed.
    package init(
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        directions: [(name: String, predicate: (Output) -> Bool)],
        hitsPerDirection: Int,
        maxAttemptsPerDirection: Int,
        seed: UInt64? = nil
    ) {
        self.gen = gen
        self.property = property
        self.directions = directions
        self.hitsPerDirection = hitsPerDirection
        self.maxAttemptsPerDirection = maxAttemptsPerDirection
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
    package mutating func run() -> ClassificationExploreResult<Output> {
        let directionCount = directions.count
        let startTime = DispatchTime.now()
        let totalPool = directionCount * maxAttemptsPerDirection
        var state = RunState(directionCount: directionCount, totalPool: totalPool)
        let warmupCount = max(100, hitsPerDirection)

        // MARK: Warm-up

        let warmupBudget = min(warmupCount, state.remainingPool)
        var interpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: prng.seed,
            maxRuns: UInt64(warmupBudget)
        )

        while let (value, tree) = try? interpreter.next() {
            state.warmupSamplesDrawn += 1
            state.remainingPool -= 1
            state.propertyInvocations += 1

            let matching = classify(value)
            state.coOccurrence.recordSample(matchingDirections: matching)

            for directionIndex in matching {
                state.hits[directionIndex] += 1
                state.warmupHits[directionIndex] += 1
            }

            if property(value) == false {
                let reduced = reduce(value: value, tree: tree, matchingDirections: matching)
                let reducedDirections = classify(reduced.counterexample)
                return assembleResult(
                    state: state, failure: reduced, matchingDirections: reducedDirections,
                    startTime: startTime, termination: .propertyFailed
                )
            }
        }

        // MARK: Direction ordering and tuning passes

        var coveredDirections = Set<Int>()
        for directionIndex in 0 ..< directionCount where state.hits[directionIndex] >= hitsPerDirection {
            coveredDirections.insert(directionIndex)
        }

        while coveredDirections.count < directionCount, state.remainingPool > 0 {
            let nextDirection = (0 ..< directionCount)
                .filter { coveredDirections.contains($0) == false }
                .max(by: { state.hits[$0] < state.hits[$1] })

            guard let targetDirection = nextDirection else { break }

            let passBudget = min(maxAttemptsPerDirection, state.remainingPool)
            guard passBudget > 0 else { break }

            if let failureResult = runTuningPass(
                targetDirection: targetDirection,
                passBudget: passBudget,
                directionCount: directionCount,
                state: &state,
                startTime: startTime
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
            startTime: startTime, termination: termination
        )
    }

    // MARK: - Tuning pass

    // swiftlint:disable:next function_body_length
    private mutating func runTuningPass(
        targetDirection: Int,
        passBudget: Int,
        directionCount: Int,
        state: inout RunState,
        startTime: DispatchTime
    ) -> ClassificationExploreResult<Output>? {
        let tunedGen: ReflectiveGenerator<Output>
        do {
            tunedGen = try ChoiceGradientTuner.tune(
                gen,
                predicate: directions[targetDirection].predicate,
                warmupRuns: 400,
                sampleCount: 20,
                seed: GenerationContext.runSeed(
                    base: prng.seed,
                    runIndex: UInt64(targetDirection)
                ),
                subdivisionThresholds: .relaxed
            )
        } catch {
            let directionName = directions[targetDirection].name
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_tune_error",
                "direction=\(directionName) error=\(error)"
            )
            return nil
        }

        var passSamplesDrawn = 0
        var passInterpreter = ValueAndChoiceTreeInterpreter(
            tunedGen,
            materializePicks: false,
            seed: GenerationContext.runSeed(
                base: prng.seed,
                runIndex: UInt64(directionCount + targetDirection)
            ),
            maxRuns: UInt64(passBudget)
        )

        while passSamplesDrawn < passBudget,
              state.hits[targetDirection] < hitsPerDirection,
              let (value, _) = try? passInterpreter.next()
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
                let untunedTree = try? Interpreters.reflect(gen, with: value)
                let reduced = reduce(value: value, tree: untunedTree, matchingDirections: matching)
                let reducedDirections = classify(reduced.counterexample)
                state.remainingPool += passBudget - passSamplesDrawn
                return assembleResult(
                    state: state, failure: reduced, matchingDirections: reducedDirections,
                    startTime: startTime, termination: .propertyFailed
                )
            }
        }

        state.remainingPool += passBudget - passSamplesDrawn
        return nil
    }

    // MARK: - Classification

    private func classify(_ value: Output) -> [Int] {
        var matching = [Int]()
        for (index, direction) in directions.enumerated() {
            if direction.predicate(value) {
                matching.append(index)
            }
        }
        return matching
    }

    // MARK: - Reduction

    private func reduce(
        value: Output,
        tree: ChoiceTree?,
        matchingDirections: [Int]
    ) -> ReducedFailure<Output> {
        guard let reduceTree = tree ?? (try? Interpreters.reflect(gen, with: value)) else {
            return ReducedFailure(counterexample: value, original: value, reducedSequence: nil)
        }

        let reductionPredicate: (Output) -> Bool
        if matchingDirections.isEmpty {
            reductionPredicate = { [property] output in
                property(output) == false
            }
        } else {
            reductionPredicate = { [property, directions] output in
                for directionIndex in matchingDirections {
                    if directions[directionIndex].predicate(output) == false {
                        return false
                    }
                }
                return property(output) == false
            }
        }

        do {
            if let (reducedSequence, reducedValue) = try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: reduceTree,
                output: value,
                config: .init(maxStalls: 2),
                property: { reductionPredicate($0) == false }
            ) {
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
        startTime: DispatchTime,
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

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

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
    package var counterexample: Output?
    package var original: Output?
    package var reducedSequence: ChoiceSequence?
    package var counterexampleDirections: [Int]
    package var directionCoverage: [DirectionCoverageEntry]
    package var coOccurrence: CoOccurrenceMatrix
    package var propertyInvocations: Int
    package var warmupSamples: Int
    package var totalMilliseconds: Double
    package var termination: ClassificationExploreTermination
    package var seed: UInt64

    package struct DirectionCoverageEntry {
        package var name: String
        package var hits: Int
        package var tuningPassSamples: Int
        package var tuningPassPasses: Int
        package var tuningPassFailures: Int
        package var warmupHits: Int
        package var isCovered: Bool
        package var warmupRuleOfThreeBound: Double?
        package var tuningPassRuleOfThreeBound: Double?
    }
}

/// How a classification-aware exploration run terminated.
package enum ClassificationExploreTermination: Sendable {
    case propertyFailed
    case coverageAchieved
    case budgetExhausted
}
