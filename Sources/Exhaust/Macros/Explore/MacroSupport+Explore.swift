// Explore family: directed property testing with per-direction CGS tuning.

import ExhaustCore
import Foundation
import IssueReporting

#if canImport(Testing)
    #if canImport(ObjectiveC)
        @_weakLinked import Testing
    #else
        import Testing // swiftlint:disable:this duplicate_imports
    #endif
#endif

public extension __ExhaustRuntime {
    // MARK: - Explore (Bool)

    /// Runs a directed property test with per-direction CGS tuning. Runtime target of `#explore`.
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
        var budget: ExhaustBudget = .standard
        var seed: UInt64?
        var suppress = SuppressFlags()
        var logLevel: LogLevel = .error
        let logFormat: LogFormat = .keyValue
        var shouldParallelize = false
        for setting in settings {
            switch setting {
                case let .budget(exploreBudget):
                    budget = exploreBudget
                case let .replay(replaySeed):
                    guard let resolved = replaySeed.resolve() else {
                        reportError(
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
                            invocations: ExploreInvocationCounts(
                                warmup: 0,
                                regression: 0,
                                directedSampling: 0,
                                reduction: 0,
                                diagnostic: 0
                            ),
                            warmup: nil,
                            totalMilliseconds: 0,
                            termination: .budgetExhausted
                        )
                    }
                    seed = resolved.seed
                case let .suppress(option):
                    suppress.apply(option)
                case let .log(level):
                    logLevel = level
                case .parallelize:
                    shouldParallelize = true
            }
        }

        #if canImport(Testing)
            if let traitConfig = ExhaustTraitConfiguration.current {
                let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
                if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                    budget = traitBudget
                }
            }
        #endif
        budget.preconditionValid()

        if shouldParallelize, seed != nil, suppress.issueReporting == false {
            reportWarning(
                ".parallelize has no effect with .replay: replay runs sequentially for deterministic reproduction.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }

        let namedDirections = directions.map { direction in
            (name: direction.0, predicate: { (value: Output) in direction.1(value) })
        }

        var regressionSeeds: [UInt64] = []
        #if canImport(Testing)
            if let traitConfig = ExhaustTraitConfiguration.current {
                for encodedSeed in traitConfig.regressions {
                    guard let decoded = ReplaySeed.decodeWithIteration(encodedSeed) else {
                        reportError(
                            "Invalid regression seed: \(encodedSeed)",
                            fileID: fileID, filePath: filePath, line: line, column: column
                        )
                        continue
                    }
                    regressionSeeds.append(decoded.seed)
                }
            }
        #endif

        return ExhaustLog.withConfiguration(suppress.logConfiguration(minimumLevel: logLevel, format: logFormat)) {
            let result: DirectedExploreResult<Output>
            do {
                result = try { () throws -> DirectedExploreResult<Output> in
                    if shouldParallelize, seed == nil, namedDirections.count > 1 {
                        return try runParallelExplore(
                            gen: gen,
                            property: property,
                            directions: namedDirections,
                            hitsPerDirection: budget.hitsPerDirection,
                            maxAttemptsPerDirection: budget.maxAttemptsPerDirection,
                            seed: seed
                        )
                    }
                    var runner = DirectedExploreRunner(
                        gen: gen,
                        property: property,
                        directions: namedDirections,
                        hitsPerDirection: budget.hitsPerDirection,
                        maxAttemptsPerDirection: budget.maxAttemptsPerDirection,
                        seed: seed,
                        regressionSeeds: regressionSeeds
                    )
                    return try runner.run()
                }()
            } catch {
                reportError(
                    "Generator failed during exploration: \(error)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return ExploreReport(
                    result: nil,
                    seed: seed ?? 0,
                    directionCoverage: [],
                    coOccurrence: CoOccurrenceMatrix(directionCount: 0),
                    counterexampleDirections: [],
                    invocations: ExploreInvocationCounts(
                        warmup: 0,
                        regression: 0,
                        directedSampling: 0,
                        reduction: 0,
                        diagnostic: 0
                    ),
                    warmup: nil,
                    totalMilliseconds: 0,
                    termination: .budgetExhausted
                )
            }

            let warmupRan = result.warmupSamples != nil
            let directionCoverage = result.directionCoverage.map { entry in
                let outcome: DirectionOutcome = if entry.isCovered {
                    .covered
                } else if let tuningError = entry.tuningError {
                    .tuningFailed(tuningError)
                } else {
                    .uncovered
                }
                return DirectionCoverage(
                    name: entry.name,
                    hits: entry.hits,
                    directedSamplingSamples: entry.directedSamplingSamples,
                    directedSamplingPasses: entry.directedSamplingPasses,
                    directedSamplingFailures: entry.directedSamplingFailures,
                    outcome: outcome,
                    warmup: warmupRan ? DirectionWarmup(hits: entry.warmupHits) : nil
                )
            }

            let termination: ExploreTermination = switch result.termination {
                case .propertyFailed: .propertyFailed
                case .coverageAchieved: .coverageAchieved
                case .budgetExhausted: .budgetExhausted
            }
            let invocations = ExploreInvocationCounts(
                warmup: result.invocations.warmup,
                regression: result.invocations.regression,
                directedSampling: result.invocations.directedSampling,
                reduction: result.invocations.reduction,
                diagnostic: 0
            )

            if let counterexample = result.counterexample {
                let matchedDirections = result.counterexampleDirections.map { index in
                    (index: index, name: directionCoverage[index].name)
                }
                var failure = ExploreFailure(
                    counterexample: counterexample,
                    original: result.original,
                    seed: result.seed,
                    invocations: invocations,
                    directedSamplingBudget: directions.count * budget.maxAttemptsPerDirection,
                    matchedDirections: matchedDirections,
                    reducedSequence: result.reducedSequence
                )
                failure.reductionProducedNoImprovement = result.reducedSequence == nil
                let rendered = failure.render()
                if suppress.issueReporting == false {
                    reportError(
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
                    "warmup_samples": result.warmupSamples.map { "\($0)" } ?? "none",
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

            let exploreReport = ExploreReport(
                result: result.counterexample,
                seed: result.seed,
                directionCoverage: directionCoverage,
                coOccurrence: result.coOccurrence,
                counterexampleDirections: result.counterexampleDirections,
                invocations: invocations,
                warmup: result.warmupSamples.map { WarmupStats(samples: $0) },
                totalMilliseconds: result.totalMilliseconds,
                termination: termination
            )
            reportExploreCoverageIssues(
                report: exploreReport,
                suppressIssueReporting: suppress.issueReporting,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return exploreReport
        }
    }

    // MARK: - Coverage Issue Reporting

    /// Fails or warns on a passing explore run whose stated goals were not met.
    ///
    /// A run that never invoked the property asserts nothing and reports an error regardless of `.suppress(.issueReporting)`, matching the `#exhaust` pointless-run error. A direction the run never reached defeats the point of `#explore`, so it also reports an error; a direction whose tuning failed reports a warning, since that can be a tuning limitation rather than a generator or predicate defect. Both of those respect suppression so a caller asserting on the returned report can opt out.
    static func reportExploreCoverageIssues(
        report: ExploreReport<some Any>,
        suppressIssueReporting: Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        guard report.result == nil else { return }

        if report.propertyInvocations == 0 {
            reportError(
                "The property was never invoked, so this test asserts nothing. Check the budget: zero hits per direction and zero attempts leave nothing to run.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return
        }

        guard suppressIssueReporting == false else { return }

        let uncoveredNames = report.directionCoverage
            .filter { $0.outcome == .uncovered }
            .map(\.name)
        if uncoveredNames.isEmpty == false {
            reportError(
                "Exploration never reached \(uncoveredNames.count == 1 ? "direction" : "directions") \(uncoveredNames.map { "\"\($0)\"" }.joined(separator: ", ")) within the directed sampling budget. The generator cannot produce matching values, or the predicate never holds. Widen the generator, fix the predicate, or raise the budget.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }

        let tuningFailedNames = report.directionCoverage
            .filter { if case .tuningFailed = $0.outcome { true } else { false } }
            .map(\.name)
        if tuningFailedNames.isEmpty == false {
            reportWarning(
                "Tuning failed for \(tuningFailedNames.count == 1 ? "direction" : "directions") \(tuningFailedNames.map { "\"\($0)\"" }.joined(separator: ", ")). Coverage for \(tuningFailedNames.count == 1 ? "this direction" : "these directions") was not achieved.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    // MARK: - Explore (Expect)

    /// Runs a directed property test with a Void/#expect/#require closure.
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
            withRoutedExpectedIssue(isIntermittent: true) {
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

            guard var report = pipelineResult else {
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

            let suppressIssueReporting = settings.contains { setting in
                if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                return false
            }
            if let counterexample = report.result {
                if suppressIssueReporting == false {
                    report.invocations.diagnostic += 1
                    do {
                        try property(counterexample)
                    } catch {}

                    let encoded = ReplaySeed.Resolved.sampling(seed: report.seed, iteration: nil).encoded
                    reportError(
                        "Reproduce: .replay(\"\(encoded)\")",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }
            } else {
                // The pipeline ran with issue reporting suppressed inside withRoutedExpectedIssue, so its coverage issues never surfaced. Re-report them here with the caller's own suppression setting.
                reportExploreCoverageIssues(
                    report: report,
                    suppressIssueReporting: suppressIssueReporting,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }

            return report
        }
    }

    // MARK: - Explore (Async)

    /// Runs a directed property test with an async Bool-returning closure.
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
        #if canImport(Testing)
            let traitConfig = ExhaustTraitConfiguration.current
        #endif
        return await dispatchToGCD(reserving: LaneReservation.single) {
            let run = {
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
            #if canImport(Testing)
                return ExhaustTraitConfiguration.$current.withValue(traitConfig, operation: run)
            #else
                return run()
            #endif
        }
    }

    // MARK: - Explore (Async Expect)

    /// Runs a directed property test with an async Void/#expect/#require closure.
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
        #if canImport(Testing)
            let traitConfig = ExhaustTraitConfiguration.current
        #endif

        return await dispatchToGCD(reserving: LaneReservation.single) {
            nonisolated(unsafe) var pipelineResult: ExploreReport<Output>?
            // withExpectedIssue cannot be used on a GCD thread because Test.current is nil, causing TestContext to misdetect as .xcTest. Use withKnownIssue directly since the async path is always in a Swift Testing context.
            #if canImport(Testing)
                ExhaustTraitConfiguration.$current.withValue(traitConfig) {
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

            guard var report = pipelineResult else {
                return __explore(
                    refGen,
                    settings: settings,
                    directions: directions,

                    property: { _ in true }
                )
            }

            let suppressIssueReporting = settings.contains { setting in
                if case let .suppress(option) = setting, option == .issueReporting || option == .all { return true }
                return false
            }
            if let counterexample = report.result {
                if suppressIssueReporting == false {
                    report.invocations.diagnostic += 1
                    let valueBox = UnsafeSendableBox(counterexample)
                    __ExhaustRuntime.blockingAwait {
                        try? await property(valueBox.value)
                    }

                    let encoded = ReplaySeed.Resolved.sampling(seed: report.seed, iteration: nil).encoded
                    reportError(
                        "Reproduce: .replay(\"\(encoded)\")",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }
            } else {
                // The pipeline ran with issue reporting suppressed inside withKnownIssue, so its coverage issues never surfaced. Re-report them here with the caller's own suppression setting.
                reportExploreCoverageIssues(
                    report: report,
                    suppressIssueReporting: suppressIssueReporting,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }

            return report
        }
    }
}
