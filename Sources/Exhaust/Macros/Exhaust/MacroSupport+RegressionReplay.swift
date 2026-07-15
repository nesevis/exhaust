import ExhaustCore

#if canImport(Testing) && canImport(ObjectiveC)
    @_weakLinked import Testing
#elseif canImport(Testing)
    import Testing
#endif

// MARK: - Regression Replay

extension __ExhaustRuntime {
    #if canImport(Testing)
        /// Replays regression seeds from the test trait and returns the first failing counterexample, if any.
        static func replayRegressionSeeds<Output>( // swiftlint:disable:this function_parameter_count
            gen: Generator<Output>,
            settings: [PropertySettings],
            skipCounter: SkipCounter? = nil,
            forceIssueReportingSuppression: Bool,
            fileID: StaticString,
            filePath: StaticString,
            line: UInt,
            column: UInt,
            function: StaticString,
            property: @escaping @Sendable (Output) -> Bool
        ) -> (counterexample: Output, replaySeed: String, report: ExhaustReport)? {
            guard let traitConfig = ExhaustTraitConfiguration.current else { return nil }
            for encodedSeed in traitConfig.regressions {
                guard ReplaySeed.Resolved.decode(encodedSeed) != nil
                else {
                    reportError(
                        "Invalid regression seed: \(encodedSeed)",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                    continue
                }
                var replayReport = ExhaustReport()
                var replaySettings = settings.filter { setting in
                    if case .replay = setting { return false }
                    return true
                }
                replaySettings.append(.replay(.encoded(encodedSeed)))
                if forceIssueReportingSuppression {
                    replaySettings.append(.suppress(.issueReporting))
                }
                replaySettings.append(.onReport { replayReport = $0 })
                let replayResult = __exhaustBody(
                    gen: gen,
                    settings: replaySettings,
                    reflecting: nil,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    testName: "\(function)",
                    property: property
                ).0
                replayReport.skippedInvocations = skipCounter?.drain() ?? 0
                if replayResult == nil {
                    // Seed now passes — the bug was fixed. The seed sits inert as a
                    // silent regression guard until the property fails again.
                } else if let counterexample = replayResult {
                    return (
                        counterexample,
                        replaySeed: encodedSeed,
                        report: replayReport
                    )
                }
            }
            return nil
        }
    #endif
}

// MARK: - Deferred Report Delivery

extension __ExhaustRuntime {
    /// Holds `.onReport` closures outside the Bool pipeline so an assertion wrapper can include its final diagnostic rerun before delivering the report.
    struct DeferredReportDelivery {
        let pipelineSettings: [PropertySettings]
        private let reportClosures: [(ExhaustReport) -> Void]

        init(settings: [PropertySettings]) {
            var pipelineSettings = [PropertySettings]()
            var reportClosures = [(ExhaustReport) -> Void]()
            for setting in settings {
                switch setting {
                    case let .onReport(closure):
                        reportClosures.append(closure)
                    default:
                        pipelineSettings.append(setting)
                }
            }
            self.pipelineSettings = pipelineSettings
            self.reportClosures = reportClosures
        }

        func deliver(_ report: ExhaustReport) {
            for closure in reportClosures {
                closure(report)
            }
        }
    }
}
