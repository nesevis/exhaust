import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("#explore(time:) runtime entry", .serialized)
struct ExploreTimeRuntimeTests {
    @Test("Missing instrumentation fails immediately, before any budget is consumed")
    func missingInstrumentation() {
        FuzzInstrumentationCheck.overrideForTesting.withValue { $0 = false }
        defer {
            FuzzInstrumentationCheck.overrideForTesting.withValue { $0 = nil }
        }
        var report: FuzzReport?
        withKnownIssue {
            report = #explore(#gen(.int(in: 0 ... 100)), time: .seconds(60)) { value in
                value >= 0
            }
        }
        #expect(report?.termination == .instrumentationMissing)
        #expect(report?.totalAttempts == 0)
        #expect(report?.elapsed == .zero)
    }

    @Test("An unresolvable replay seed is a configuration error, not a run")
    func invalidReplaySeed() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.replay("!!!not-a-seed!!!")],
            source: passthroughSource(),
            configure: nil,
            property: { _ in .pass }
        )
        guard case .invalidConfiguration = report.termination else {
            Issue.record("Expected invalidConfiguration, got \(report.termination)")
            return
        }
        #expect(report.totalAttempts == 0)
    }

    @Test("A nonpositive time budget is a configuration error, not a run")
    func nonpositiveBudget() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .zero,
            settings: [],
            source: passthroughSource(),
            configure: nil,
            property: { _ in .pass }
        )
        guard case .invalidConfiguration = report.termination else {
            Issue.record("Expected invalidConfiguration, got \(report.termination)")
            return
        }
        #expect(report.totalAttempts == 0)
    }

    @Test("An attempt-limited run wraps the runner result into the public report")
    func reportWrapping() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: passthroughSource(),
            configure: { configuration in
                configuration.attemptLimit = 800
            },
            property: { value in
                value == 42 ? .fail(.returnedFalse) : .pass
            }
        )
        #expect(report.termination == .attemptLimitReached)
        #expect(report.totalAttempts >= 800)
        #expect(report.totalAttempts == report.evaluatedSearchCases + report.rejectedSearchAttempts)
        #expect(report.totalPropertyInvocations == report.evaluatedSearchCases
            + report.pruneInvocations
            + report.reductionInvocations
            + report.normalizationInvocations
            + report.classificationInvocations
            + report.recoveryInvocations
            + report.diagnosticInvocations)
        #expect(report.seed == 7)
        #expect(report.attemptsPerSecond > 0)
        #expect(report.coveredEdgeCount > 0)
        #expect(report.instrumentedEdgeCount == 32)
        #expect(report.clusters.count == 1)
        #expect(report.testingOverheadFraction >= 0)
        #expect(report.testingOverheadFraction <= 1)
        if let cluster = report.clusters.first {
            #expect(cluster.reducedDescription == "42")
            #expect(cluster.symptoms == ["returnedFalse"])
            #expect(cluster.instanceCount >= cluster.reducedCount)
            #expect(cluster.reducedCount >= 1)
            #expect(cluster.firstSeen <= cluster.lastSeen)
            // The reduced form 42 hits only edge 2 (42 % 10); passing values also land there, but far below 100%.
            #expect(cluster.necessaryEdgeCount == 1)
            #expect(cluster.discriminatingEdges.first?.edgeIndex == 2)
            #expect(cluster.discriminatingEdges.first?.failureHitFraction == 1.0)
            // Synthetic edge indices address no real program counters, so no location resolves.
            #expect(cluster.discriminatingEdges.allSatisfy { $0.location == nil })
        }
    }

    @Test("Timed assertion diagnostics re-materialize the reduced counterexample")
    func timedAssertionDiagnosticReplay() {
        let generator = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)
        var report = __ExhaustRuntime.runExploreTimeCore(
            gen: generator,
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: passthroughSource(),
            configure: { configuration in
                configuration.attemptLimit = 800
            },
            property: { value in
                value == 42 ? .fail(.returnedFalse) : .pass
            }
        )
        let replayedValues = UnsafeSendableBox<[Int]>([])
        let invocationsBeforeReplay = report.totalPropertyInvocations

        __ExhaustRuntime.replayFuzzDiagnostics(
            report: &report,
            gen: generator,
            suppressIssueReporting: false,
            property: { value in
                replayedValues.value.append(value)
            }
        )

        #expect(replayedValues.value == [42])
        #expect(report.diagnosticInvocations == 1)
        #expect(report.totalPropertyInvocations == invocationsBeforeReplay + 1)
    }

    @Test("Async timed assertion diagnostics await the reduced counterexample")
    func asyncTimedAssertionDiagnosticReplay() async {
        let generator = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)
        var report = __ExhaustRuntime.runExploreTimeCore(
            gen: generator,
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: passthroughSource(),
            configure: { configuration in
                configuration.attemptLimit = 800
            },
            property: { value in
                value == 42 ? .fail(.returnedFalse) : .pass
            }
        )
        let replayedValues = UnsafeSendableBox<[Int]>([])

        await __ExhaustRuntime.replayFuzzDiagnosticsAsync(
            report: &report,
            gen: generator,
            suppressIssueReporting: false,
            property: { value in
                await Task.yield()
                replayedValues.value.append(value)
            }
        )

        #expect(replayedValues.value == [42])
        #expect(report.diagnosticInvocations == 1)
    }

    @Test("Reports are deterministic under a pinned seed, modulo task-completion timing")
    func reportDeterminism() {
        func run() -> FuzzReport {
            __ExhaustRuntime.runExploreTimeCore(
                gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
                time: .seconds(60),
                settings: [.replay(11), .suppress(.all)],
                source: passthroughSource(),
                configure: { configuration in
                    configuration.attemptLimit = 800
                },
                property: { value in
                    value == 42 ? .fail(.returnedFalse) : .pass
                }
            )
        }
        let first = run()
        let second = run()
        #expect(first.termination == second.termination)
        #expect(first.clusters.map(\.reducedDescription) == second.clusters.map(\.reducedDescription))
        #expect(
            first.clusters.map { $0.discriminatingEdges.map(\.edgeIndex) }
                == second.clusters.map { $0.discriminatingEdges.map(\.edgeIndex) }
        )
        #expect(first.clusters.map(\.necessaryEdgeCount) == second.clusters.map(\.necessaryEdgeCount))
        #expect(first.corpusEntryCount == second.corpusEntryCount)
        #expect(first.coveredEdgeCount == second.coveredEdgeCount)
    }

    @Test("The fault inventory is reported as an issue unless suppressed")
    func inventoryReporting() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: passthroughSource(),
            configure: { configuration in
                configuration.attemptLimit = 800
            },
            property: { value in
                value == 42 ? .fail(.returnedFalse) : .pass
            }
        )
        #expect(report.clusters.isEmpty == false)

        // Suppressed: nothing may be recorded (a stray issue fails this test on its own).
        __ExhaustRuntime.reportFuzzIssues(
            report: report,
            suppressIssueReporting: true,
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )

        // Unsuppressed: the rendered inventory is recorded as an error.
        withKnownIssue {
            __ExhaustRuntime.reportFuzzIssues(
                report: report,
                suppressIssueReporting: false,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }

        let summary = __ExhaustRuntime.renderFuzzSummary(report)
        #expect(summary.contains("1 fault cluster"))
        #expect(summary.contains("42"))
        #expect(summary.contains(".replay(7)"))
    }

    @Test("suppress(.attachments) and suppress(.all) both parse into the attachment flag")
    func suppressAttachmentsParsing() {
        #expect(ParsedFuzzSettings([.suppress(.attachments)]).suppressAttachments)
        #expect(ParsedFuzzSettings([.suppress(.attachments)]).suppressIssueReporting == false)
        #expect(ParsedFuzzSettings([.suppress(.attachments)]).suppressLogs == false)
        #expect(ParsedFuzzSettings([.suppress(.all)]).suppressAttachments)
        #expect(ParsedFuzzSettings([.suppress(.issueReporting)]).suppressAttachments == false)
    }

    @Test("Terminal suspects collapse duplicate function names, keeping the line-bearing form")
    func suspectsCollapseDuplicateNames() {
        // Three renderings of the same function — full line, line 0 (interior edge), and no file at all — plus one genuinely distinct suspect. Only the line-bearing form of the duplicate and the distinct suspect should survive.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, location: "ExecuteFixture.RacyLedger.audit() + 24 (RacyLedger.swift:45)"),
            makeEdge(index: 2, location: "ExecuteFixture.RacyLedger.audit() + 80 (RacyLedger.swift:0)"),
            makeEdge(index: 3, location: "ExecuteFixture.RacyLedger.audit() + 96"),
            makeEdge(index: 4, location: "ExecuteFixture.RacyLedger.deposit(_:) + 12 (RacyLedger.swift:36)"),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(for: makeCluster(discriminatingEdges: edges))
        #expect(suspects == [
            "RacyLedger.audit (RacyLedger.swift:45)",
            "RacyLedger.deposit (RacyLedger.swift:36)",
        ])
    }

    @Test("Terminal suspects keep distinct line references within one function")
    func suspectsKeepDistinctLines() {
        // Two resolved lines in the same function are distinct locations; only the line-less rendering collapses.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, location: "ExecuteFixture.RacyLedger.audit() + 24 (RacyLedger.swift:45)"),
            makeEdge(index: 2, location: "ExecuteFixture.RacyLedger.audit() + 80 (RacyLedger.swift:52)"),
            makeEdge(index: 3, location: "ExecuteFixture.RacyLedger.audit() + 96 (RacyLedger.swift:0)"),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(for: makeCluster(discriminatingEdges: edges))
        #expect(suspects == [
            "RacyLedger.audit (RacyLedger.swift:45)",
            "RacyLedger.audit (RacyLedger.swift:52)",
        ])
    }

    @Test("Terminal suspects prefer the line-bearing form even when it ranks behind a line-less duplicate")
    func suspectsPreferLineBearingForm() {
        // The line-less form leads the edge ranking; the collapse must still keep the line-bearing rendering.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, location: "ExecuteFixture.RacyLedger.audit() + 96 (RacyLedger.swift:0)"),
            makeEdge(index: 2, location: "ExecuteFixture.RacyLedger.audit() + 24 (RacyLedger.swift:45)"),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(for: makeCluster(discriminatingEdges: edges))
        #expect(suspects == ["RacyLedger.audit (RacyLedger.swift:45)"])
    }

    @Test("A run whose property never ran reports the pointless-run error even when suppressed")
    func pointlessRun() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.suppress(.all)],
            source: passthroughSource(),
            configure: { configuration in
                configuration.attemptLimit = 0
            },
            property: { _ in .pass }
        )
        #expect(report.totalAttempts == 0)
        withKnownIssue {
            __ExhaustRuntime.reportFuzzIssues(
                report: report,
                suppressIssueReporting: true,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }
    }

    @Test("Verdict wrapping distinguishes false, thrown, and skip")
    func verdictWrapping() {
        let boolProperty = __ExhaustRuntime.wrapVerdictProperty { (value: Int) -> Bool in
            if value == 0 {
                return false
            }
            if value == 1 {
                throw MarkerError()
            }
            if value == 2 {
                throw PropertySkip()
            }
            return true
        }
        #expect(boolProperty(0).isFailure)
        guard case let .fail(symptom) = boolProperty(1) else {
            Issue.record("Expected a thrown-error failure")
            return
        }
        #expect(symptom.kind == "MarkerError")
        #expect(boolProperty(2).isFailure == false)
        #expect(boolProperty(3).isFailure == false)

        let detectionProperty = __ExhaustRuntime.wrapVerdictDetection { (value: Int) in
            if value == 0 {
                throw MarkerError()
            }
        }
        #expect(detectionProperty(0).isFailure)
        #expect(detectionProperty(1).isFailure == false)
    }

    #if canImport(ObjectiveC)
        @Test("An NSException raised by the property is caught in-process and treated as an ordinary failure")
        func nsExceptionCaught() {
            let property = __ExhaustRuntime.wrapVerdictProperty { (value: Int) -> Bool in
                if value == 0 {
                    NSException(name: .invalidArgumentException, reason: "planted", userInfo: nil).raise()
                }
                return true
            }
            guard case let .fail(symptom) = property(0) else {
                Issue.record("Expected the raised NSException to become a failure verdict")
                return
            }
            #expect(symptom.kind == "NSException(NSInvalidArgumentException)")
            #expect(property(1).isFailure == false)
        }
    #endif
}

// MARK: - Helpers

private struct MarkerError: Error {}

private func makeEdge(index: Int, location: String?) -> FuzzReport.DiscriminatingEdge {
    FuzzReport.DiscriminatingEdge(
        edgeIndex: index,
        failureHitFraction: 1.0,
        passingHitFraction: 0.0,
        location: location
    )
}

private func makeCluster(discriminatingEdges: [FuzzReport.DiscriminatingEdge]) -> FuzzReport.Cluster {
    FuzzReport.Cluster(
        id: 0,
        reducedDescription: "value",
        symptoms: ["returnedFalse"],
        instanceCount: 1,
        reducedCount: 1,
        unnormalizedMemberCount: 0,
        isLikelySplit: false,
        discoveringPhase: .sampling,
        firstSeen: .seconds(1),
        firstSeenAttempt: 1,
        lastSeen: .seconds(1),
        discriminatingEdges: discriminatingEdges,
        necessaryEdgeCount: discriminatingEdges.count,
        nearMissEdgeIndices: [],
        reducedSequence: []
    )
}

private func passthroughSource() -> SyntheticCoverageSource<Int> {
    SyntheticCoverageSource<Int>(edgeCount: 32, edges: { value in
        var edges = [abs(value) % 10]
        if value > 50 {
            edges.append(10)
        }
        return edges
    })
}
