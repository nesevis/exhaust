// Explore family: classification-aware property testing with per-direction CGS tuning.

import ExhaustCore
import Foundation
import IssueReporting

#if canImport(Testing)
    @_weakLinked import Testing
#endif

public extension __ExhaustRuntime {
    // MARK: - Explore (Bool)

    /// Runs a classification-aware property test with per-direction CGS tuning. Runtime target of `#explore`.
    @discardableResult
    static func __explore<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @Sendable @escaping (Output) -> Bool
    ) -> ExploreReport<Output> {
        let gen = refGen.gen
        var budget: ExploreBudget = .standard
        var seed: UInt64?
        var suppressIssueReporting = false
        var suppressLogs = false
        var logLevel: LogLevel = .error
        var logFormat: LogFormat = .keyValue
        var shouldParallelize = false
        for setting in settings {
            switch setting {
            case let .budget(exploreBudget):
                budget = exploreBudget
            case let .replay(replaySeed):
                seed = replaySeed.resolve()
                if seed == nil {
                    reportIssue(
                        "Invalid replay seed: \(replaySeed)",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                    return ExploreReport(
                        result: nil,
                        seed: 0,
                        directionCoverage: [],
                        coOccurrence: CoOccurrenceMatrix(directionCount: 0),
                        counterexampleDirections: [],
                        propertyInvocations: 0,
                        warmupSamples: 0,
                        totalMilliseconds: 0,
                        termination: .budgetExhausted
                    )
                }
            case let .suppress(option):
                switch option {
                case .issueReporting:
                    suppressIssueReporting = true
                case .logs:
                    suppressLogs = true
                case .all:
                    suppressIssueReporting = true
                    suppressLogs = true
                }
            case let .logging(level, format):
                logLevel = level
                logFormat = format
            case .parallelize:
                shouldParallelize = true
            }
        }

        let namedDirections = directions.map { direction in
            (name: direction.0, predicate: { (value: Output) in direction.1(value) })
        }

        return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
            let result: ClassificationExploreResult<Output>
            do {
                result = try Gen.$isInterpreting.withValue(true) { () throws -> ClassificationExploreResult<Output> in
                    if shouldParallelize, seed == nil, namedDirections.count > 1 {
                        return try runParallelExplore(
                            gen: gen,
                            property: property,
                            directions: namedDirections,
                            hitsPerDirection: budget.hitsPerDirection,
                            maxAttemptsPerDirection: budget.maxAttemptsPerDirection
                        )
                    }
                    var runner = ClassificationExploreRunner(
                        gen: gen,
                        property: property,
                        directions: namedDirections,
                        hitsPerDirection: budget.hitsPerDirection,
                        maxAttemptsPerDirection: budget.maxAttemptsPerDirection,
                        seed: seed
                    )
                    return try runner.run()
                }
            } catch {
                reportIssue(
                    "Generator failed during exploration: \(error)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return ExploreReport(
                    result: nil,
                    seed: seed ?? 0,
                    directionCoverage: [],
                    coOccurrence: CoOccurrenceMatrix(directionCount: 0),
                    counterexampleDirections: [],
                    propertyInvocations: 0,
                    warmupSamples: 0,
                    totalMilliseconds: 0,
                    termination: .budgetExhausted
                )
            }

            let directionCoverage = result.directionCoverage.map { entry in
                DirectionCoverage(
                    name: entry.name,
                    hits: entry.hits,
                    tuningPassSamples: entry.tuningPassSamples,
                    tuningPassPasses: entry.tuningPassPasses,
                    tuningPassFailures: entry.tuningPassFailures,
                    warmupHits: entry.warmupHits,
                    isCovered: entry.isCovered,
                    warmupRuleOfThreeBound: entry.warmupRuleOfThreeBound,
                    tuningPassRuleOfThreeBound: entry.tuningPassRuleOfThreeBound
                )
            }

            let termination: ExploreTermination = switch result.termination {
            case .propertyFailed: .propertyFailed
            case .coverageAchieved: .coverageAchieved
            case .budgetExhausted: .budgetExhausted
            }

            if let counterexample = result.counterexample {
                let matchedDirections = result.counterexampleDirections.map { index in
                    (index: index, name: directionCoverage[index].name)
                }
                let failure = ExploreFailure(
                    counterexample: counterexample,
                    original: result.original,
                    seed: result.seed,
                    propertyInvocations: result.propertyInvocations,
                    totalBudget: directions.count * budget.maxAttemptsPerDirection,
                    matchedDirections: matchedDirections,
                    reducedSequence: result.reducedSequence
                )
                let rendered = failure.render()
                if suppressIssueReporting == false {
                    reportIssue(
                        rendered,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }
            } else {
                var passMetadata = [
                    "invocations": "\(result.propertyInvocations)",
                    "warmup_samples": "\(result.warmupSamples)",
                    "seed": "\(result.seed)",
                ]
                let coveredCount = directionCoverage.filter(\.isCovered).count
                passMetadata["coverage"] = "\(coveredCount)/\(directions.count)"
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "explore_property_passed",
                    metadata: passMetadata
                )
            }

            return ExploreReport(
                result: result.counterexample,
                seed: result.seed,
                directionCoverage: directionCoverage,
                coOccurrence: result.coOccurrence,
                counterexampleDirections: result.counterexampleDirections,
                propertyInvocations: result.propertyInvocations,
                warmupSamples: result.warmupSamples,
                totalMilliseconds: result.totalMilliseconds,
                termination: termination
            )
        }
    }

    // MARK: - Explore (Expect)

    /// Runs a classification-aware property test with a Void/#expect/#require closure.
    @discardableResult
    static func __exploreExpect<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @Sendable (Output) throws -> Void,
        detection: @Sendable (Output) throws -> Void
    ) -> ExploreReport<Output> {
        withoutActuallyEscaping(detection) { detection in
            let boolProperty = wrapDetectionProperty(detection)

            nonisolated(unsafe) var pipelineResult: ExploreReport<Output>?
            withExpectedIssue(isIntermittent: true) {
                pipelineResult = __explore(
                    refGen,
                    settings: settings + [.suppress(.issueReporting)],
                    directions: directions,

                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    property: boolProperty
                )
            }

            guard let report = pipelineResult else {
                return __explore(
                    refGen,
                    settings: settings,
                    directions: directions,

                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    property: { _ in true }
                )
            }

            if let counterexample = report.result {
                let suppressIssueReporting = settings.contains { setting in
                    if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                    return false
                }
                if suppressIssueReporting == false {
                    do {
                        try property(counterexample)
                    } catch {}

                    let encoded = CrockfordBase32.encode(report.seed)
                    reportIssue(
                        "Reproduce: .replay(\"\(encoded)\")",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }
            }

            return report
        }
    }

    // MARK: - Explore (Async)

    /// Runs a classification-aware property test with an async Bool-returning closure.
    @discardableResult
    static func __exploreAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> ExploreReport<Output> {
        let syncProperty = bridgeAsyncProperty(property)
        return await dispatchToGCD {
            __explore(
                refGen,
                settings: settings,
                directions: directions,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
                property: syncProperty
            )
        }
    }

    // MARK: - Explore (Async Expect)

    /// Runs a classification-aware property test with an async Void/#expect/#require closure.
    @discardableResult
    static func __exploreExpectAsync<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],

        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Void,
        detection: @escaping @Sendable (Output) throws -> Void
    ) async -> ExploreReport<Output> {
        let boolProperty = wrapDetectionProperty(detection)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                nonisolated(unsafe) var pipelineResult: ExploreReport<Output>?
                // withExpectedIssue cannot be used on a GCD thread because Test.current is nil, causing TestContext to misdetect as .xcTest. Use withKnownIssue directly since the async path is always in a Swift Testing context.
                #if canImport(Testing)
                    withKnownIssue(isIntermittent: true) {
                        pipelineResult = __explore(
                            refGen,
                            settings: settings + [.suppress(.issueReporting)],
                            directions: directions,

                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column,
                            property: boolProperty
                        )
                    }
                #else
                    pipelineResult = __explore(
                        refGen,
                        settings: settings + [.suppress(.issueReporting)],
                        directions: directions,

                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        property: boolProperty
                    )
                #endif

                guard let report = pipelineResult else {
                    let emptyReport = __explore(
                        refGen,
                        settings: settings,
                        directions: directions,

                        property: { _ in true }
                    )
                    continuation.resume(returning: emptyReport)
                    return
                }

                if let counterexample = report.result {
                    let suppressIssueReporting = settings.contains { setting in
                        if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                        return false
                    }
                    if suppressIssueReporting == false {
                        let valueBox = UnsafeSendableBox(counterexample)
                        __ExhaustRuntime.blockingAwait {
                            try? await property(valueBox.value)
                        }

                        let encoded = CrockfordBase32.encode(report.seed)
                        reportIssue(
                            "Reproduce: .replay(\"\(encoded)\")",
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                    }
                }

                continuation.resume(returning: report)
            }
        }
    }
}

// MARK: - Parallel Explore

private extension __ExhaustRuntime {
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
