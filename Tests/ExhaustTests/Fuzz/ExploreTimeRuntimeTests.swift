import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("#explore(time:) runtime entry", .serialized)
struct ExploreTimeRuntimeTests {
    @Test("Missing instrumentation fails immediately, before any budget is consumed")
    func missingInstrumentation() {
        var report: FuzzReport?
        withKnownIssue {
            report = __ExhaustRuntime.__exploreTime(
                #gen(.int(in: 0 ... 100)),
                time: .seconds(60),
                settings: [],
                coverage: .none
            ) { value in
                value >= 0
            }
        }
        #expect(report?.termination == .instrumentationMissing)
        #expect(report?.attempts.total == 0)
        #expect(report?.timing.elapsed == .zero)
    }

    // MARK: - Per-Variant Reporting Channel

    // One test per value entry point of the shape "the run's recorded issue reaches the current test". The recorded issue here is the missing-instrumentation error (the suite runs uninstrumented, and the override pins that), which travels the same reportFuzzIssues tail as the fault inventory. withKnownIssue is task-scoped, so a variant that reports off the test task — as the async Bool variant once did from inside its GCD closure — fails its test here instead of silently losing the report.

    @Test("The sync Bool entry point records its issue on the test task")
    func reportingChannelSyncBool() {
        nonisolated(unsafe) var report: FuzzReport?
        withKnownIssue {
            report = __ExhaustRuntime.__exploreTime(
                #gen(.int(in: 0 ... 100)),
                time: .seconds(60),
                settings: [],
                coverage: .none
            ) { value in
                value >= 0
            }
        }
        #expect(report?.termination == .instrumentationMissing)
    }

    @Test("The sync expect entry point records its issue on the test task")
    func reportingChannelSyncExpect() {
        nonisolated(unsafe) var report: FuzzReport?
        withKnownIssue {
            report = __ExhaustRuntime.__exploreTimeExpect(
                #gen(.int(in: 0 ... 100)),
                time: .seconds(60),
                settings: [],
                coverage: .none,
                property: { _ in },
                detection: { _ in }
            )
        }
        #expect(report?.termination == .instrumentationMissing)
    }

    @Test("The async Bool entry point records its issue on the test task, after the GCD hop")
    func reportingChannelAsyncBool() async {
        nonisolated(unsafe) var report: FuzzReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__exploreTimeAsync(
                #gen(.int(in: 0 ... 100)),
                time: .seconds(60),
                settings: [],
                coverage: .none
            ) { value in
                value >= 0
            }
        }
        #expect(report?.termination == .instrumentationMissing)
    }

    @Test("The async expect entry point records its issue on the test task, after the GCD hop")
    func reportingChannelAsyncExpect() async {
        nonisolated(unsafe) var report: FuzzReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__exploreTimeExpectAsync(
                #gen(.int(in: 0 ... 100)),
                time: .seconds(60),
                settings: [],
                coverage: .none,
                property: { _ in },
                detection: { _ in }
            )
        }
        #expect(report?.termination == .instrumentationMissing)
    }

    @Test("The skipScreening setting starts the search at random sampling with no screening attempts")
    func skipScreeningSetting() {
        func run(settings: [PropertyFuzzSettings]) -> FuzzReport {
            __ExhaustRuntime.runExploreTimeCore(
                gen: Gen.choose(in: 0 ... 1000),
                time: .seconds(60),
                settings: settings,
                source: .injected(SyntheticCoverageSource<Int>(edgeCount: 16, edges: { value in [value % 8] })),
                configure: { configuration in
                    configuration.attemptLimit = 400
                },
                property: { _ in .pass }
            )
        }
        let skipped = run(settings: [.replay(1), .suppress(.all), .skipScreening])
        #expect(skipped.attempts.screening == 0)
        #expect(skipped.attempts.sampling > 0)

        let defaulted = run(settings: [.replay(1), .suppress(.all)])
        #expect(defaulted.attempts.screening > 0)
    }

    @Test("A failure found on a path the run could not see is still reported beside the no-coverage error")
    func unreachableCoverageKeepsTheInventory() {
        // The unseen path is exactly where the message says the code may be running (inlined into an uninstrumented caller, or on another executor), so a fault there must not vanish behind the coverage diagnostic.
        let source = SyntheticCoverageSource<Int>(edgeCount: 4, reportsLiveCoverage: true, edges: { _ in [] })
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100),
            time: .seconds(60),
            settings: [.replay(1), .suppress(.all)],
            source: .injected(source),
            configure: { configuration in
                configuration.attemptLimit = 200
            },
            property: { value in value == 42 ? .fail(.returnedFalse) : .pass }
        )
        #expect(report.termination == .coverageUnreachable)
        #expect(report.clusters.count == 1)
        #expect(report.renderedSummary().contains("found at least 1 distinct failure"))
    }

    @Test("A live source that records nothing stops the run at the reachability threshold")
    func unreachableCoverageStopsEarly() {
        let attemptLimit = FuzzTunables.coverageUnreachableAttemptThreshold + 200
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 1000),
            time: .seconds(60),
            settings: [.replay(1), .suppress(.all)],
            source: .injected(SyntheticCoverageSource<Int>(edgeCount: 4, reportsLiveCoverage: true, edges: { _ in [] })),
            configure: { configuration in
                configuration.attemptLimit = attemptLimit
            },
            property: { _ in .pass }
        )
        #expect(report.termination == .coverageUnreachable)
        #expect(report.attempts.total >= FuzzTunables.coverageUnreachableAttemptThreshold)
        #expect(report.attempts.total < attemptLimit)
    }

    @Test("A live source that records nothing is reported even when the budget ends before the reachability threshold")
    func unreachableCoverageReportedBelowThreshold() {
        // The suite recipe pairs a few-seconds budget with a debug build; on a slow property the budget can expire before the early-stop threshold, and the run must still say it searched nothing rather than pass green.
        let source = SyntheticCoverageSource<Int>(edgeCount: 4, reportsLiveCoverage: true, edges: { _ in [] })
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100),
            time: .seconds(60),
            settings: [.replay(1), .suppress(.all)],
            source: .injected(source),
            configure: { configuration in
                configuration.attemptLimit = FuzzTunables.coverageUnreachableAttemptThreshold / 10
            },
            property: { _ in .pass }
        )
        #expect(report.termination == .coverageUnreachable)
        #expect(report.attempts.evaluated > 0)
    }

    @Test("A synthetic source that records nothing is not mistaken for unreachable coverage")
    func syntheticSourceIsExemptFromReachabilityCheck() {
        let attemptLimit = FuzzTunables.coverageUnreachableAttemptThreshold + 200
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 1000),
            time: .seconds(60),
            settings: [.replay(1), .suppress(.all)],
            source: .injected(SyntheticCoverageSource<Int>(edgeCount: 4, edges: { _ in [] })),
            configure: { configuration in
                configuration.attemptLimit = attemptLimit
            },
            property: { _ in .pass }
        )
        #expect(report.termination == .attemptLimitReached)
    }

    @Test("An unresolvable replay seed is a configuration error, not a run")
    func invalidReplaySeed() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.replay("!!!not-a-seed!!!")],
            source: .injected(passthroughSource()),
            configure: nil,
            property: { _ in .pass }
        )
        guard case .invalidConfiguration = report.termination else {
            Issue.record("Expected invalidConfiguration, got \(report.termination)")
            return
        }
        #expect(report.attempts.total == 0)
    }

    @Test("A screening replay seed is a configuration error, not a run", arguments: ["19-U3", "19-U3L5"])
    func screeningReplaySeedRejected(encodedSeed: String) {
        // The digits before the U marker are a covering-array seed, not a run seed. Honoring them as one would silently run a different search than the row the seed names, so both screening forms fail configuration instead.
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.replay(.encoded(encodedSeed))],
            source: .injected(passthroughSource()),
            configure: nil,
            property: { _ in .pass }
        )
        guard case .invalidConfiguration = report.termination else {
            Issue.record("Expected invalidConfiguration, got \(report.termination)")
            return
        }
        #expect(report.attempts.total == 0)
    }

    @Test("A nonpositive time budget is a configuration error, not a run")
    func nonpositiveBudget() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .zero,
            settings: [],
            source: .injected(passthroughSource()),
            configure: nil,
            property: { _ in .pass }
        )
        guard case .invalidConfiguration = report.termination else {
            Issue.record("Expected invalidConfiguration, got \(report.termination)")
            return
        }
        #expect(report.attempts.total == 0)
    }

    @Test("An attempt-limited run wraps the runner result into the public report")
    func reportWrapping() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: .injected(passthroughSource()),
            configure: { configuration in
                configuration.attemptLimit = 800
            },
            property: { value in
                value == 42 ? .fail(.returnedFalse) : .pass
            }
        )
        #expect(report.termination == .attemptLimitReached)
        #expect(report.attempts.total >= 800)
        #expect(report.attempts.total == report.attempts.evaluated + report.attempts.rejected)
        #expect(report.invocations.total == report.attempts.evaluated
            + report.invocations.prune
            + report.invocations.reduction
            + report.invocations.normalization
            + report.invocations.classification
            + report.invocations.recovery
            + report.invocations.diagnostic)
        #expect(report.seed == 7)
        #expect(report.attemptsPerSecond > 0)
        #expect(report.coverage.coveredEdges > 0)
        #expect(report.coverage.instrumentedEdges == 32)
        #expect(report.clusters.count == 1)
        #expect(report.timing.testingOverheadFraction >= 0)
        #expect(report.timing.testingOverheadFraction <= 1)
        let timing = report.timing
        let attributedNanoseconds = timing.property.nanoseconds
            + timing.screeningOverhead.nanoseconds
            + timing.samplingOverhead.nanoseconds
            + timing.mutationOverhead.nanoseconds
            + timing.reduction.nanoseconds
            + timing.other.nanoseconds
        #expect(attributedNanoseconds == report.timing.elapsed.nanoseconds)
        #expect(timing.property > .zero)
        #expect(timing.screeningOverhead > .zero)
        if let cluster = report.clusters.first {
            #expect(cluster.reducedDescription == "42")
            #expect(cluster.symptoms == ["returnedFalse"])
            #expect(cluster.instanceCount >= cluster.reducedCount)
            #expect(cluster.reducedCount >= 1)
            #expect(cluster.firstSeen <= cluster.lastSeen)
            // The reduced form 42 hits only edge 2 (42 % 10); passing values also land there, but far below 100%.
            #expect(cluster.discriminatingEdges.first?.edgeIndex == 2)
            #expect(cluster.discriminatingEdges.first?.failureHitFraction == 1.0)
            // Synthetic edge indices address no real program counters, so no symbol resolves.
            #expect(cluster.discriminatingEdges.allSatisfy { $0.symbol == nil })
        }
    }

    @Test("Timed assertion diagnostics re-materialize the reduced counterexample")
    func timedAssertionDiagnosticReplay() {
        let generator = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)
        var report = __ExhaustRuntime.runExploreTimeCore(
            gen: generator,
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: .injected(passthroughSource()),
            configure: { configuration in
                configuration.attemptLimit = 800
            },
            property: { value in
                value == 42 ? .fail(.returnedFalse) : .pass
            }
        )
        let replayedValues = UnsafeSendableBox<[Int]>([])
        let invocationsBeforeReplay = report.invocations.total

        __ExhaustRuntime.replayFuzzDiagnostics(
            report: &report,
            gen: generator,
            suppressIssueReporting: false,
            property: { value in
                replayedValues.value.append(value)
            }
        )

        #expect(replayedValues.value == [42])
        #expect(report.invocations.diagnostic == 1)
        #expect(report.invocations.total == invocationsBeforeReplay + 1)
    }

    @Test("Async timed assertion diagnostics await the reduced counterexample")
    func asyncTimedAssertionDiagnosticReplay() async {
        let generator = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)
        var report = __ExhaustRuntime.runExploreTimeCore(
            gen: generator,
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: .injected(passthroughSource()),
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
        #expect(report.invocations.diagnostic == 1)
    }

    @Test("Reports are deterministic under a pinned seed, modulo task-completion timing")
    func reportDeterminism() {
        func run() -> FuzzReport {
            __ExhaustRuntime.runExploreTimeCore(
                gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
                time: .seconds(60),
                settings: [.replay(11), .suppress(.all)],
                source: .injected(passthroughSource()),
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
        #expect(first.clusters.map { $0.discriminatingEdges.map(\.edgeIndex) } == second.clusters.map { $0.discriminatingEdges.map(\.edgeIndex) })
        #expect(first.coverage.corpusEntryCount == second.coverage.corpusEntryCount)
        #expect(first.coverage.coveredEdges == second.coverage.coveredEdges)
    }

    @Test("The fault inventory is reported as an issue unless suppressed")
    func inventoryReporting() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.replay(7), .suppress(.all)],
            source: .injected(passthroughSource()),
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
        #expect(summary.contains("found at least 1 distinct failure"))
        #expect(summary.contains("42"))
        #expect(summary.contains(".replay(7)"))
    }

    @Test("suppress(.attachments) and suppress(.all) both parse into the attachment flag")
    func suppressAttachmentsParsing() {
        #expect(ParsedPropertyFuzzSettings([.suppress(.attachments)]).suppress.attachments)
        #expect(ParsedPropertyFuzzSettings([.suppress(.attachments)]).suppress.issueReporting == false)
        #expect(ParsedPropertyFuzzSettings([.suppress(.attachments)]).suppress.logs == false)
        #expect(ParsedPropertyFuzzSettings([.suppress(.all)]).suppress.attachments)
        #expect(ParsedPropertyFuzzSettings([.suppress(.issueReporting)]).suppress.attachments == false)
    }

    @Test("Terminal suspects collapse duplicate function names, keeping the line-bearing form")
    func suspectsCollapseDuplicateNames() {
        // Three edges in the same function: a resolved line, line 0 (an interior edge), and no file at all, plus one genuinely distinct suspect. Only the line-bearing form of the duplicate and the distinct suspect should survive.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, symbol: makeSymbol("RacyLedger.audit()", file: "RacyLedger.swift", line: 45)),
            makeEdge(index: 2, symbol: makeSymbol("RacyLedger.audit()", file: "RacyLedger.swift", line: nil)),
            makeEdge(index: 3, symbol: makeSymbol("RacyLedger.audit()", file: nil, line: nil)),
            makeEdge(index: 4, symbol: makeSymbol("RacyLedger.deposit(_:)", file: "RacyLedger.swift", line: 36)),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(for: makeCluster(discriminatingEdges: edges))
        #expect(suspects == [
            "RacyLedger.audit() (RacyLedger.swift:45)",
            "RacyLedger.deposit(_:) (RacyLedger.swift:36)",
        ])
    }

    @Test("Terminal suspects keep distinct line references within one function")
    func suspectsKeepDistinctLines() {
        // Two resolved lines in the same function are distinct locations; only the line-less edge collapses.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, symbol: makeSymbol("RacyLedger.audit()", file: "RacyLedger.swift", line: 45)),
            makeEdge(index: 2, symbol: makeSymbol("RacyLedger.audit()", file: "RacyLedger.swift", line: 52)),
            makeEdge(index: 3, symbol: makeSymbol("RacyLedger.audit()", file: "RacyLedger.swift", line: nil)),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(for: makeCluster(discriminatingEdges: edges))
        #expect(suspects == [
            "RacyLedger.audit() (RacyLedger.swift:45)",
            "RacyLedger.audit() (RacyLedger.swift:52)",
        ])
    }

    @Test("Terminal suspects prefer the line-bearing form even when it ranks behind a line-less duplicate")
    func suspectsPreferLineBearingForm() {
        // The line-less edge leads the ranking; the collapse must still keep the line-bearing rendering.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, symbol: makeSymbol("RacyLedger.audit()", file: "RacyLedger.swift", line: nil)),
            makeEdge(index: 2, symbol: makeSymbol("RacyLedger.audit()", file: "RacyLedger.swift", line: 45)),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(for: makeCluster(discriminatingEdges: edges))
        #expect(suspects == ["RacyLedger.audit() (RacyLedger.swift:45)"])
    }

    @Test("Terminal suspects drop edges that symbolized into synthesized bodies")
    func suspectsDropCompilerGenerated() {
        // Debug info files a derived conformance's body under a pseudo-path. It names no branch a reader can act on, so it never reaches a suspect line.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, symbol: makeSymbol("static RacyLedger.== infix(_:_:)", file: "/<compiler-generated>", line: 0)),
            makeEdge(index: 2, symbol: makeSymbol("RacyLedger.deposit(_:)", file: "RacyLedger.swift", line: 36)),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(for: makeCluster(discriminatingEdges: edges))
        #expect(suspects == ["RacyLedger.deposit(_:) (RacyLedger.swift:36)"])
    }

    @Test("A symbol renders its name alone without a file, and name plus file without a line")
    func symbolRendering() {
        #expect(makeSymbol("reconcile()", file: nil, line: nil).rendered == "reconcile()")
        #expect(makeSymbol("reconcile()", file: "RacyLedger.swift", line: nil).rendered == "reconcile() (RacyLedger.swift)")
        #expect(makeSymbol("reconcile()", file: "RacyLedger.swift", line: 72).rendered == "reconcile() (RacyLedger.swift:72)")
    }

    @Test("A run whose property never ran reports the pointless-run error even when suppressed")
    func pointlessRun() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.suppress(.all)],
            source: .injected(passthroughSource()),
            configure: { configuration in
                configuration.attemptLimit = 0
            },
            property: { _ in .pass }
        )
        #expect(report.attempts.total == 0)
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
        #expect(boolProperty(2).isDiscard)
        #expect(boolProperty(3).isFailure == false)
        #expect(boolProperty(3).isDiscard == false)

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

private func makeEdge(index: Int, symbol: FuzzReport.SymbolLocation?) -> FuzzReport.DiscriminatingEdge {
    FuzzReport.DiscriminatingEdge(
        edgeIndex: index,
        failureHitFraction: 1.0,
        passingHitFraction: 0.0,
        symbol: symbol
    )
}

private func makeSymbol(_ displayName: String, module: String? = "SpecFixture", file: String?, line: Int?) -> FuzzReport.SymbolLocation {
    FuzzReport.SymbolLocation(module: module, displayName: displayName, fullName: displayName, file: file, line: line)
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

@Suite("Discriminating edge folding")
struct DiscriminatingEdgeFoldingTests {
    @Test("Edges of one function fold onto its distinct resolved lines, in ranked order")
    func foldsOffsetsOntoLines() {
        // The shape one IFC cluster ranked: a single getter at five offsets. Two resolved lines survive; the unresolved offset and the repeats fold away.
        let getter = "RegLabel.allBelow.getter"
        let candidates = [
            makeEdge(index: 29, symbol: makeSymbol(getter, module: "IFCMachine", file: "RegisterMachine.swift", line: 66)),
            makeEdge(index: 30, symbol: makeSymbol(getter, module: "IFCMachine", file: "RegisterMachine.swift", line: 67)),
            makeEdge(index: 31, symbol: makeSymbol(getter, module: "IFCMachine", file: "RegisterMachine.swift", line: nil)),
            makeEdge(index: 32, symbol: makeSymbol(getter, module: "IFCMachine", file: "RegisterMachine.swift", line: 67)),
            makeEdge(index: 39, symbol: makeSymbol(getter, module: "IFCMachine", file: "RegisterMachine.swift", line: 67)),
            makeEdge(index: 1575, symbol: makeSymbol("regStep(_:_:)", module: "IFCMachine", file: "RegisterMachine.swift", line: 692)),
        ]
        let folded = __ExhaustRuntime.distinctSuspectEdges(candidates, symbolized: true, limit: 5)
        #expect(folded.map(\.edgeIndex) == [29, 30, 1575])
    }

    @Test("Synthesized bodies are dropped and an unplaced symbol folds with itself")
    func dropsSynthesizedAndFoldsUnplaced() {
        // The STLC shapes: a derived equality body, a private function atos could not place (two edges, one symbol), and a function with a line.
        let candidates = [
            makeEdge(index: 3, symbol: makeSymbol("static STLCType.== infix(_:_:)", module: "STLC", file: "/<compiler-generated>", line: 0)),
            makeEdge(index: 130, symbol: makeSymbol("stlcSubstImpl(_:_:_:config:)", module: "STLC", file: nil, line: nil)),
            makeEdge(index: 131, symbol: makeSymbol("stlcSubstImpl(_:_:_:config:)", module: "STLC", file: nil, line: nil)),
            makeEdge(index: 98, symbol: makeSymbol("stlcGetType(_:_:)", module: "STLC", file: "STLC.swift", line: 91)),
            makeEdge(index: 99, symbol: makeSymbol("stlcGetType(_:_:)", module: "STLC", file: "STLC.swift", line: 91)),
        ]
        let folded = __ExhaustRuntime.distinctSuspectEdges(candidates, symbolized: true, limit: 5)
        #expect(folded.map(\.edgeIndex) == [130, 98])
    }

    @Test("Unlocated edges are kept without symbolization and dropped with it")
    func unlocatedEdgesFollowSymbolization() {
        let candidates = [makeEdge(index: 7, symbol: nil), makeEdge(index: 8, symbol: nil)]
        #expect(__ExhaustRuntime.distinctSuspectEdges(candidates, symbolized: false, limit: 5).map(\.edgeIndex) == [7, 8])
        #expect(__ExhaustRuntime.distinctSuspectEdges(candidates, symbolized: true, limit: 5).isEmpty)
    }

    @Test("The limit caps distinct locations, not candidates")
    func limitCountsDistinctLocations() {
        let candidates = (0 ..< 8).map { index in
            makeEdge(index: index, symbol: makeSymbol("function\(index)()", file: "File.swift", line: 10 + index))
        }
        #expect(__ExhaustRuntime.distinctSuspectEdges(candidates, symbolized: true, limit: 3).map(\.edgeIndex) == [0, 1, 2])
    }
}

@Suite("Symbol classification")
struct SymbolClassificationTests {
    @Test("Compiler-generated globals are recognized on the mangled name")
    func mangledClassification() {
        // A type metadata accessor, a reabstraction thunk, an outlined copy, a merged function, and a protocol witness thunk.
        for mangled in ["$s4STLC10STLCConfigVMa", "$s4STLC1fyyFTR", "$s4STLC8STLCExprOWOy", "$s4STLC1gyyFTm", "$s4STLC4TypeVSQAASQ2eeoiySbx_xtFZTW"] {
            #expect(SancovSymbolizer.isCompilerGenerated(mangled: mangled), "\(mangled)")
        }
        // A plain function, a specialization of one, a C symbol, and a getter.
        for mangled in ["$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF", "$s4STLC1fyyFTf4d_n", "_exhaust_tpg_bind", "$s4STLC8RegLabelV8allBelowSayACGvg"] {
            #expect(SancovSymbolizer.isCompilerGenerated(mangled: mangled) == false, "\(mangled)")
        }
    }

    @Test("The module is the first identifier of a mangled Swift name")
    func moduleName() {
        #expect(SancovSymbolizer.moduleName(ofMangled: "$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF") == "STLC")
        #expect(SancovSymbolizer.moduleName(ofMangled: "$s10IFCMachine8RegLabelO8allBelowSayACGvg") == "IFCMachine")
        #expect(SancovSymbolizer.moduleName(ofMangled: "$sSa6appendyyxF") == "Swift")
        #expect(SancovSymbolizer.moduleName(ofMangled: "_exhaust_tpg_bind") == nil)
    }

    @Test("Specialization wrappers strip to the function in both demangler forms")
    func specializationStripping() {
        #expect(SancovSymbolizer.stripSpecialization("function signature specialization <Arg[2] = Dead> of STLC.stlcGetType([STLC.STLCType], STLC.STLCExpr) -> STLC.STLCType?") == "STLC.stlcGetType([STLC.STLCType], STLC.STLCExpr) -> STLC.STLCType?")
        #expect(SancovSymbolizer.stripSpecialization("specialized stlcGetType(_:_:)") == "stlcGetType(_:_:)")
        #expect(SancovSymbolizer.stripSpecialization("stlcGetType(_:_:)") == "stlcGetType(_:_:)")
    }

    #if os(macOS)
        @Test("The simplifier renders the debugger's form for the shapes the IFC and STLC dumps produced")
        func simplifiedNames() throws {
            let names = SancovSymbolizer.simplifiedNames(forMangled: [
                "$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF",
                "$s10IFCMachine8RegLabelO8allBelowSayACGvg",
                "$s4STLC13stlcSubstImpl33_1954C2AFCB1824DC713E91E170B31520LLyAA0A4ExprOSi_A2E6configAA0A6ConfigVtF",
                "$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtFTf4d_n",
            ])
            // The toolchain tool may be absent on a bare runner; then nothing renders and the full demangling stands in.
            try #require(names.isEmpty == false, "swift-demangle unavailable")
            #expect(names["$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF"] == "stlcGetType(_:_:)")
            #expect(names["$s10IFCMachine8RegLabelO8allBelowSayACGvg"] == "RegLabel.allBelow.getter")
            #expect(names["$s4STLC13stlcSubstImpl33_1954C2AFCB1824DC713E91E170B31520LLyAA0A4ExprOSi_A2E6configAA0A6ConfigVtF"]?.hasPrefix("stlcSubstImpl(") == true)
            #expect(names["$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtFTf4d_n"] == "stlcGetType(_:_:)")
        }
    #endif
}
