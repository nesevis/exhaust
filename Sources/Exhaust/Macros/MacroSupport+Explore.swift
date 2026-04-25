// Explore family: classification-aware property testing with per-direction CGS tuning.

import ExhaustCore
import Foundation
import IssueReporting

#if canImport(Testing)
    @_weakLinked import Testing
#endif

extension __ExhaustRuntime {
    // MARK: - Explore (Bool)

    /// Runs a classification-aware property test with per-direction CGS tuning. Runtime target of `#explore`.
    @discardableResult
    public static func __explore<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @Sendable @escaping (Output) -> Bool
    ) -> ExploreReport<Output> {
        var budget: ExploreBudget = .expedient
        var seed: UInt64?
        var suppressIssueReporting = false
        var suppressLogs = false
        var logLevel: LogLevel = .error
        var logFormat: LogFormat = .keyValue
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
            }
        }

        return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
            var runner = ClassificationExploreRunner(
                gen: gen,
                property: property,
                directions: directions.map { (name: $0.0, predicate: $0.1) },
                hitsPerDirection: budget.hitsPerDirection,
                maxAttemptsPerDirection: budget.maxAttemptsPerDirection,
                seed: seed
            )
            let result = runner.run()

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
                    matchedDirections: matchedDirections
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
                if let sourceCode {
                    passMetadata["source"] = sourceCode
                }
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
    public static func __exploreExpect<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],
        sourceCode: String?,
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
                    gen,
                    settings: settings + [.suppress(.issueReporting)],
                    directions: directions,
                    sourceCode: sourceCode,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    property: boolProperty
                )
            }

            guard let report = pipelineResult else {
                return __explore(
                    gen,
                    settings: settings,
                    directions: directions,
                    sourceCode: sourceCode,
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
    public static func __exploreAsync<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @escaping @Sendable (Output) async throws -> Bool
    ) async -> ExploreReport<Output> {
        let syncProperty = bridgeAsyncProperty(property)
        return await dispatchToGCD {
            __explore(
                gen,
                settings: settings,
                directions: directions,
                sourceCode: sourceCode,
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
    public static func __exploreExpectAsync<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        directions: [(String, @Sendable (Output) -> Bool)],
        sourceCode: String?,
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
                            gen,
                            settings: settings + [.suppress(.issueReporting)],
                            directions: directions,
                            sourceCode: sourceCode,
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column,
                            property: boolProperty
                        )
                    }
                #else
                    pipelineResult = __explore(
                        gen,
                        settings: settings + [.suppress(.issueReporting)],
                        directions: directions,
                        sourceCode: sourceCode,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                        property: boolProperty
                    )
                #endif

                guard let report = pipelineResult else {
                    let emptyReport = __explore(
                        gen,
                        settings: settings,
                        directions: directions,
                        sourceCode: sourceCode,
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
                        let valueBox = SendableBox(counterexample)
                        let semaphore = DispatchSemaphore(value: 0)
                        Task { @Sendable in
                            try? await property(valueBox.value)
                            semaphore.signal()
                        }
                        semaphore.wait()

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
