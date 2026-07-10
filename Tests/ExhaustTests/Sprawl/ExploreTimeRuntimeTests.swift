import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("#explore(time:) runtime entry", .serialized)
struct ExploreTimeRuntimeTests {
    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
    @Test("Missing instrumentation fails immediately, before any budget is consumed")
    func missingInstrumentation() {
        SprawlInstrumentationCheck.overrideForTesting.withValue { $0 = false }
        defer {
            SprawlInstrumentationCheck.overrideForTesting.withValue { $0 = nil }
        }
        var report: SprawlReport?
        withKnownIssue {
            report = #explore(#gen(.int(in: 0 ... 100)), time: .seconds(60)) { value in
                value >= 0
            }
        }
        #expect(report?.termination == .instrumentationMissing)
        #expect(report?.totalAttempts == 0)
        #expect(report?.elapsed == .zero)
    }

    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
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

    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
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

    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
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
        #expect(report.seed == 7)
        #expect(report.attemptsPerSecond > 0)
        #expect(report.coveredEdgeCount > 0)
        #expect(report.instrumentedEdgeCount == 32)
        #expect(report.clusters.count == 1)
        #expect(report.frameworkOverheadFraction >= 0)
        #expect(report.frameworkOverheadFraction <= 1)
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

    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
    @Test("Reports are deterministic under a pinned seed, modulo task-completion timing")
    func reportDeterminism() {
        func run() -> SprawlReport {
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

    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
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
        __ExhaustRuntime.reportSprawlIssues(
            report: report,
            suppressIssueReporting: true,
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )

        // Unsuppressed: the rendered inventory is recorded as an error.
        withKnownIssue {
            __ExhaustRuntime.reportSprawlIssues(
                report: report,
                suppressIssueReporting: false,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }

        let summary = __ExhaustRuntime.renderSprawlSummary(report)
        #expect(summary.contains("1 fault cluster"))
        #expect(summary.contains("42"))
        #expect(summary.contains(".replay(7)"))
    }

    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
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
            __ExhaustRuntime.reportSprawlIssues(
                report: report,
                suppressIssueReporting: true,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }
    }

    @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
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
        @available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
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

private func passthroughSource() -> SyntheticCoverageSource<Int> {
    SyntheticCoverageSource<Int>(edgeCount: 32, edges: { value in
        var edges = [abs(value) % 10]
        if value > 50 {
            edges.append(10)
        }
        return edges
    })
}
