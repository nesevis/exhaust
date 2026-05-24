// Parallel explore: per-direction CGS tuning lanes via GCD concurrentPerform.

import ExhaustCore
import Foundation

extension __ExhaustRuntime {
    /// Aggregated results from a single direction's CGS tuning and sampling lane.
    ///
    /// Marked `@unchecked Sendable` because each lane writes exclusively to its own slot in the shared result array (indexed by `targetDirection`), and the array is read only after ``DispatchQueue.concurrentPerform`` returns.
    struct DirectionLaneResult<Output>: @unchecked Sendable {
        var targetDirection: Int
        var hits: [Int]
        var coOccurrence: CoOccurrenceMatrix
        var tuningPassSamples: Int = 0
        var tuningPassPasses: Int = 0
        var tuningPassFailures: Int = 0
        var propertyInvocations: Int = 0
        var failure: (value: Output, tree: ChoiceTree, matchingDirections: [Int])?
        var error: (any Error)?

        init(targetDirection: Int, directionCount: Int) {
            self.targetDirection = targetDirection
            hits = Array(repeating: 0, count: directionCount)
            coOccurrence = CoOccurrenceMatrix(directionCount: directionCount)
        }
    }

    // swiftlint:disable:next function_body_length
    /// Runs all direction tuning and sampling lanes concurrently via ``DispatchQueue.concurrentPerform``, merges per-lane results, and reduces the first failure found (if any).
    static func runParallelExplore<Output>(
        gen: Generator<Output>,
        property: @escaping (Output) -> Bool,
        directions: [(name: String, predicate: (Output) -> Bool)],
        hitsPerDirection: Int,
        maxAttemptsPerDirection: Int
    ) throws -> ClassificationExploreResult<Output> {
        let directionCount = directions.count
        let startTime = DispatchTime.now()
        let baseSeed = Xoshiro256().seed

        let cancelled = SendableBox(false)
        let resultStorage = SendableBox<[DirectionLaneResult<Output>?]>(
            Array(repeating: nil, count: directionCount)
        )

        nonisolated(unsafe) let unsafeProperty = property
        nonisolated(unsafe) let unsafeDirections = directions

        DispatchQueue.concurrentPerform(iterations: directionCount) { directionIndex in
            let laneResult = runDirectionLane(
                gen: gen,
                property: unsafeProperty,
                directions: unsafeDirections,
                targetDirection: directionIndex,
                directionCount: directionCount,
                hitsPerDirection: hitsPerDirection,
                maxAttemptsPerDirection: maxAttemptsPerDirection,
                baseSeed: baseSeed,
                cancelled: cancelled
            )
            resultStorage.withValue { $0[directionIndex] = laneResult }
        }

        let laneResults = resultStorage.value.compactMap(\.self)

        // Merge per-lane results.
        var mergedHits = Array(repeating: 0, count: directionCount)
        var mergedCoOccurrence = CoOccurrenceMatrix(directionCount: directionCount)
        var mergedPropertyInvocations = 0
        var perDirectionSamples = Array(repeating: 0, count: directionCount)
        var perDirectionPasses = Array(repeating: 0, count: directionCount)
        var perDirectionFailures = Array(repeating: 0, count: directionCount)
        var firstFailure: (value: Output, tree: ChoiceTree, matchingDirections: [Int])?
        var firstError: (any Error)?

        for laneResult in laneResults {
            for index in 0 ..< directionCount {
                mergedHits[index] += laneResult.hits[index]
            }
            mergedCoOccurrence.merge(laneResult.coOccurrence)
            mergedPropertyInvocations += laneResult.propertyInvocations
            let target = laneResult.targetDirection
            perDirectionSamples[target] = laneResult.tuningPassSamples
            perDirectionPasses[target] = laneResult.tuningPassPasses
            perDirectionFailures[target] = laneResult.tuningPassFailures
            if firstFailure == nil, let failure = laneResult.failure {
                firstFailure = failure
            }
            if firstError == nil, let error = laneResult.error {
                firstError = error
            }
        }

        if let error = firstError, firstFailure == nil {
            throw error
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

        var coverageEntries = [ClassificationExploreResult<Output>.DirectionCoverageEntry]()
        for (index, direction) in directions.enumerated() {
            let hits = mergedHits[index]
            coverageEntries.append(.init(
                name: direction.name,
                hits: hits,
                tuningPassSamples: perDirectionSamples[index],
                tuningPassPasses: perDirectionPasses[index],
                tuningPassFailures: perDirectionFailures[index],
                warmupHits: 0,
                isCovered: hits >= hitsPerDirection,
                warmupRuleOfThreeBound: nil,
                tuningPassRuleOfThreeBound: perDirectionPasses[index] > 0 ? 3.0 / Double(perDirectionPasses[index]) : nil
            ))
        }

        // Reduce the first failure found, if any.
        if let failure = firstFailure {
            let reducedResult = reduceExploreFailure(
                gen: gen,
                property: property,
                directions: directions,
                failure: failure
            )

            let reducedDirections = classifyExploreValue(reducedResult.counterexample, directions: directions)

            return ClassificationExploreResult(
                counterexample: reducedResult.counterexample,
                original: reducedResult.original,
                reducedSequence: reducedResult.reducedSequence,
                counterexampleDirections: reducedDirections,
                directionCoverage: coverageEntries,
                coOccurrence: mergedCoOccurrence,
                propertyInvocations: mergedPropertyInvocations,
                warmupSamples: 0,
                totalMilliseconds: elapsed,
                termination: .propertyFailed,
                seed: baseSeed
            )
        }

        let allCovered = mergedHits.allSatisfy { $0 >= hitsPerDirection }

        return ClassificationExploreResult(
            counterexample: nil,
            original: nil,
            reducedSequence: nil,
            counterexampleDirections: [],
            directionCoverage: coverageEntries,
            coOccurrence: mergedCoOccurrence,
            propertyInvocations: mergedPropertyInvocations,
            warmupSamples: 0,
            totalMilliseconds: elapsed,
            termination: allCovered ? .coverageAchieved : .budgetExhausted,
            seed: baseSeed
        )
    }

    // MARK: - Per-Direction Lane

    /// Tunes the generator for one direction via CGS, then samples up to `maxAttemptsPerDirection` values, classifying each against all directions and checking the property.
    static func runDirectionLane<Output>(
        gen: Generator<Output>,
        property: (Output) -> Bool,
        directions: [(name: String, predicate: (Output) -> Bool)],
        targetDirection: Int,
        directionCount: Int,
        hitsPerDirection: Int,
        maxAttemptsPerDirection: Int,
        baseSeed: UInt64,
        cancelled: SendableBox<Bool>
    ) -> DirectionLaneResult<Output> {
        var result = DirectionLaneResult<Output>(targetDirection: targetDirection, directionCount: directionCount)

        let tunedGen: Generator<Output>
        do {
            tunedGen = try ChoiceGradientTuner.tune(
                gen,
                predicate: directions[targetDirection].predicate,
                warmupRuns: 400,
                sampleCount: 20,
                seed: Xoshiro256.deriveSeed(from: baseSeed, at: UInt64(targetDirection)),
                subdivisionThresholds: .relaxed
            )
        } catch {
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_tune_error",
                "direction=\(directions[targetDirection].name) error=\(error)"
            )
            result.error = error
            return result
        }

        var interpreter = ValueAndChoiceTreeInterpreter(
            tunedGen,
            materializePicks: false,
            seed: Xoshiro256.deriveSeed(from: baseSeed, at: UInt64(directionCount + targetDirection)),
            maxRuns: UInt64(maxAttemptsPerDirection)
        )

        while cancelled.value == false, result.hits[targetDirection] < hitsPerDirection {
            let sample: (value: Output, tree: ChoiceTree)
            do {
                guard let next = try interpreter.next() else { break }
                sample = next
            } catch {
                result.error = error
                break
            }

            result.propertyInvocations += 1
            result.tuningPassSamples += 1

            let matching = classifyExploreValue(sample.value, directions: directions)
            result.coOccurrence.recordSample(matchingDirections: matching)

            for directionIndex in matching {
                result.hits[directionIndex] += 1
            }

            let propertyHolds = property(sample.value)
            if matching.contains(targetDirection) {
                if propertyHolds {
                    result.tuningPassPasses += 1
                } else {
                    result.tuningPassFailures += 1
                }
            }

            if propertyHolds == false {
                cancelled.value = true
                result.failure = (value: sample.value, tree: sample.tree, matchingDirections: matching)
                break
            }
        }

        return result
    }

    // MARK: - Classification

    static func classifyExploreValue<Output>(
        _ value: Output,
        directions: [(name: String, predicate: (Output) -> Bool)]
    ) -> [Int] {
        directions.enumerated()
            .filter { $0.element.predicate(value) }
            .map(\.offset)
    }

    // MARK: - Reduction

    /// Rematerializes the failure's choice tree with pick metadata, then runs the choice-graph reducer with a direction-preserving predicate.
    static func reduceExploreFailure<Output>(
        gen: Generator<Output>,
        property: @escaping (Output) -> Bool,
        directions: [(name: String, predicate: (Output) -> Bool)],
        failure: (value: Output, tree: ChoiceTree, matchingDirections: [Int])
    ) -> (counterexample: Output, original: Output, reducedSequence: ChoiceSequence?) {
        let fullTree = Materializer.materialize(
            gen,
            prefix: ChoiceSequence.flatten(failure.tree),
            mode: .exact,
            fallbackTree: failure.tree,
            materializePicks: true
        )
        let reductionTree: ChoiceTree? = switch fullTree {
            case let .success(_, rematerialized, _):
                rematerialized
            case .rejected, .failed:
                nil
        }

        guard let reduceTree = reductionTree else {
            return (failure.value, failure.value, nil)
        }

        let reductionPredicate: (Output) -> Bool = failure.matchingDirections.isEmpty
            ? { output in
                property(output) == false
            }
            : { output in
                for directionIndex in failure.matchingDirections
                    where directions[directionIndex].predicate(output) == false
                {
                    return false
                }
                return property(output) == false
            }

        do {
            if let (reducedSequence, reducedValue) = try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: reduceTree,
                output: failure.value,
                config: .init(maxStalls: 2),
                property: { reductionPredicate($0) == false }
            ) {
                return (reducedValue, failure.value, reducedSequence)
            }
        } catch {
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_reduce_error",
                "\(error)"
            )
        }

        return (failure.value, failure.value, nil)
    }
}
