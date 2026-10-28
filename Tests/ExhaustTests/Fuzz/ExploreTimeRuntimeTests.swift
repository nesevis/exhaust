import ExhaustCore
import ExhaustTestSupport
import Foundation
import IssueReporting
import Testing
@testable import Exhaust

@Suite("#explore(time:) runtime entry", .serialized)
struct ExploreTimeRuntimeTests {
    @Test("Missing instrumentation warns without invoking the property or consuming budget")
    func missingInstrumentation() async {
        let report = await __ExhaustRuntime.__exploreTimeAsync(
            #gen(.int(in: 0 ... 100)),
            time: .seconds(60),
            settings: [],
            coverage: .none
        ) { _ in
            Issue.record("An uninstrumented property must not run")
            return false
        }
        #expect(report.termination == .instrumentationMissing)
        #expect(report.attempts.total == 0)
        #expect(report.timing.elapsed == .zero)
    }

    @Test("Every entry point reports the specific missing-instrumentation warning on the test task", arguments: MissingInstrumentationEntry.allCases)
    func missingInstrumentationWarning(entry: MissingInstrumentationEntry) async {
        let reporter = RecordingIssueReporter()
        let testID = Test.current.map { String(describing: $0.id) }
        let report = await withIssueReporters([reporter]) {
            switch entry {
                case .syncBool:
                    return await __ExhaustRuntime.__exploreTimeAsync(
                        #gen(.int(in: 0 ... 100)),
                        time: .seconds(60),
                        settings: [],
                        coverage: .none
                    ) { _ in
                        Issue.record("An uninstrumented property must not run")
                        return false
                    }
                case .syncExpect:
                    return await __ExhaustRuntime.__exploreTimeExpectAsync(
                        #gen(.int(in: 0 ... 100)),
                        time: .seconds(60),
                        settings: [],
                        coverage: .none,
                        property: { _ in Issue.record("An uninstrumented property must not run") },
                        detection: { _ in Issue.record("An uninstrumented detector must not run") }
                    )
                case .asyncBool:
                    return await __ExhaustRuntime.__exploreTimeAsync(
                        #gen(.int(in: 0 ... 100)),
                        time: .seconds(60),
                        settings: [],
                        coverage: .none
                    ) { _ async in
                        Issue.record("An uninstrumented property must not run")
                        return false
                    }
                case .asyncExpect:
                    return await __ExhaustRuntime.__exploreTimeExpectAsync(
                        #gen(.int(in: 0 ... 100)),
                        time: .seconds(60),
                        settings: [],
                        coverage: .none,
                        property: { _ async in Issue.record("An uninstrumented property must not run") },
                        detection: { _ async in Issue.record("An uninstrumented detector must not run") }
                    )
            }
        }
        #expect(report.termination == .instrumentationMissing)
        #expect(report.attempts.total == 0)
        #expect(report.timing.elapsed == .zero)
        #expect(reporter.issues.map(\.message) == [__ExhaustRuntime.missingInstrumentationMessage])
        #expect(reporter.issues.allSatisfy { $0.severity == .warning && $0.testID == testID })
    }

    // MARK: - Per-Variant Reporting Channel

    // One test per value entry point of the shape "the run's recorded issue reaches the current test". The recorded issue here is the invalid-budget error, which travels the same reportFuzzIssues tail as the fault inventory. withKnownIssue is task-scoped, so a variant that reports off the test task — as the async Bool variant once did from inside its GCD closure — fails its test here instead of silently losing the report.

    @Test("The synchronous-closure Bool entry point records its issue on the test task, after the GCD hop")
    func reportingChannelSyncBool() async {
        nonisolated(unsafe) var report: FuzzReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__exploreTimeAsync(
                #gen(.int(in: 0 ... 100)),
                time: .zero,
                settings: [],
                coverage: .none
            ) { value in
                value >= 0
            }
        }
        #expect(report?.termination == .invalidConfiguration("#explore(time:) requires a positive time budget; got 0.0s."))
    }

    @Test("The synchronous-closure expect entry point records its issue on the test task, after the GCD hop")
    func reportingChannelSyncExpect() async {
        nonisolated(unsafe) var report: FuzzReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__exploreTimeExpectAsync(
                #gen(.int(in: 0 ... 100)),
                time: .zero,
                settings: [],
                coverage: .none,
                property: { _ in },
                detection: { _ in }
            )
        }
        #expect(report?.termination == .invalidConfiguration("#explore(time:) requires a positive time budget; got 0.0s."))
    }

    @Test("The async-closure Bool entry point records its issue on the test task, after the GCD hop")
    func reportingChannelAsyncBool() async {
        nonisolated(unsafe) var report: FuzzReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__exploreTimeAsync(
                #gen(.int(in: 0 ... 100)),
                time: .zero,
                settings: [],
                coverage: .none
            ) { value async in
                value >= 0
            }
        }
        #expect(report?.termination == .invalidConfiguration("#explore(time:) requires a positive time budget; got 0.0s."))
    }

    @Test("The async-closure expect entry point records its issue on the test task, after the GCD hop")
    func reportingChannelAsyncExpect() async {
        nonisolated(unsafe) var report: FuzzReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__exploreTimeExpectAsync(
                #gen(.int(in: 0 ... 100)),
                time: .zero,
                settings: [],
                coverage: .none,
                property: { _ async in },
                detection: { _ async in }
            )
        }
        #expect(report?.termination == .invalidConfiguration("#explore(time:) requires a positive time budget; got 0.0s."))
    }

    // MARK: - Closure Effects

    // Overload resolution, not the macro, picks the path: a closure without `async` must reach the direct call, and only an `async` closure may pay for a task per attempt.

    @Test("A synchronous property closure is called directly on the fuzz lane, outside any task", arguments: ClosureEffect.allCases)
    func closureEffectSelectsThePath(effect: ClosureEffect) async {
        let invocations = SendableBox((total: 0, insideTask: 0))
        let record: @Sendable () -> Void = {
            let isInsideTask = withUnsafeCurrentTask { $0 != nil }
            invocations.withValue { counts in
                counts.total += 1
                counts.insideTask += isInsideTask ? 1 : 0
            }
        }
        switch effect {
            case .synchronous:
                await __ExhaustRuntime.__exploreTimeAsync(
                    #gen(.int(in: 0 ... 100)),
                    time: .seconds(1),
                    settings: [.replay(1), .suppress(.all)],
                    coverage: .injected(passthroughSource())
                ) { _ in
                    record()
                    return true
                }
            case .asynchronous:
                await __ExhaustRuntime.__exploreTimeAsync(
                    #gen(.int(in: 0 ... 100)),
                    time: .seconds(1),
                    settings: [.replay(1), .suppress(.all)],
                    coverage: .injected(passthroughSource())
                ) { _ async in
                    record()
                    return true
                }
        }
        let counts = invocations.value
        #expect(counts.total > 0)
        switch effect {
            case .synchronous:
                #expect(counts.insideTask == 0)
            case .asynchronous:
                #expect(counts.insideTask == counts.total)
        }
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
        // The digits before the U marker are a covering array seed, not a run seed. Honoring them as one would silently run a different search than the row the seed names, so both screening forms fail configuration instead.
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

    @Test("Terminal suspects rank the property closure's module after line-less library code")
    func suspectsRankPropertyModuleLast() {
        // Under the explore command the test target is instrumented, so the property closure itself discriminates: with a resolved line it would otherwise lead the line-less decoder that selected the faulty branch.
        let edges: [FuzzReport.DiscriminatingEdge] = [
            makeEdge(index: 1, symbol: makeSymbol("closure #2 in static ParserTests.fuzz()", module: "ParserTests", file: "ParserTests.swift", line: 12)),
            makeEdge(index: 2, symbol: makeSymbol("static Parser.integrityCheck(mode:)", module: "Parser", file: "Parser.swift", line: 121)),
            makeEdge(index: 3, symbol: makeSymbol("static Parser.decodeData(_:)", module: "Parser", file: "Parser.swift", line: nil)),
            makeEdge(index: 4, symbol: makeSymbol("static Parser.decode(_:)", module: "Parser", file: "Parser.swift", line: nil)),
        ]
        let suspects = __ExhaustRuntime.terminalSuspects(
            for: makeCluster(discriminatingEdges: edges, propertyModule: "ParserTests")
        )
        #expect(suspects == [
            "static Parser.integrityCheck(mode:) (Parser.swift:121)",
            "static Parser.decodeData(_:) (Parser.swift)",
            "static Parser.decode(_:) (Parser.swift)",
        ])
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

    @Test("A run whose property discards every input reports a pointless run instead of passing")
    func allDiscardedRunReportsPointlessRun() async {
        let reporter = RecordingIssueReporter()
        let report = await DirectTestingIssues.absorbing(isIntermittent: true) {
            await withIssueReporters([reporter]) {
                await __ExhaustRuntime.__exploreTimeAsync(
                    #gen(.int(in: 0 ... 3)),
                    time: .seconds(1),
                    settings: [.replay(.numeric(1)), .suppress(.logs)],
                    coverage: .injected(SyntheticCoverageSource<Int>(edgeCount: 4, edges: { [$0] }))
                ) { _ -> Bool in
                    throw PropertySkip()
                }
            }
        }
        #expect(report.attempts.evaluated > 0)
        #expect(report.attempts.judged == 0)
        #expect(report.outcome == .error)
        #expect(reporter.issues.count == 1)
        #expect(reporter.issues.first?.message.contains("judged none of the") == true)
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

/// One generated suspect candidate: a function from a small pool so locations collide, in the property module or a library module, with no line or one of two lines.
private struct SuspectDraft {
    static let propertyModule = "FuzzTests"

    let name: Int
    let isInPropertyModule: Bool
    let line: Int

    func edge(index: Int) -> FuzzReport.DiscriminatingEdge {
        let module = switch isInPropertyModule {
            case true:
                Self.propertyModule
            case false:
                "Library"
        }
        let resolvedLine: Int? = switch line {
            case 0:
                nil
            default:
                line
        }
        return makeEdge(index: index, symbol: makeSymbol("function\(name)()", module: module, file: "File.swift", line: resolvedLine))
    }
}

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

private func makeCluster(
    discriminatingEdges: [FuzzReport.DiscriminatingEdge],
    propertyModule: String? = nil
) -> FuzzReport.Cluster {
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
        reducedSequence: [],
        reducedKey: "",
        propertyModule: propertyModule
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

    @Test("Property-module locations follow every other location and fill only the slots the rest leave free")
    func propertyModuleLocationsRankLast() {
        let gen = #gen(.int(in: 0 ... 3), .bool(), .int(in: 0 ... 2)) { name, isInPropertyModule, line in
            SuspectDraft(name: name, isInPropertyModule: isInPropertyModule, line: line)
        }
        #exhaust(#gen(gen.array(length: 0 ... 12), .int(in: 1 ... 6))) { drafts, limit in
            let candidates = drafts.enumerated().map { $0.element.edge(index: $0.offset) }
            let folded = __ExhaustRuntime.distinctSuspectEdges(
                candidates,
                symbolized: true,
                propertyModule: SuspectDraft.propertyModule,
                limit: limit
            )
            let isProperty: (FuzzReport.DiscriminatingEdge) -> Bool = {
                $0.symbol?.isInModule(SuspectDraft.propertyModule) == true
            }
            let libraryOnly = __ExhaustRuntime.distinctSuspectEdges(
                candidates.filter { isProperty($0) == false },
                symbolized: true,
                limit: limit
            )
            let unranked = __ExhaustRuntime.distinctSuspectEdges(candidates, symbolized: true, limit: candidates.count + 1)
            // Library locations are exactly the ones folding would keep without the property module, and every property location trails them.
            return folded.filter { isProperty($0) == false }.map(\.edgeIndex) == libraryOnly.map(\.edgeIndex)
                && folded.drop(while: { isProperty($0) == false }).allSatisfy { isProperty($0) }
                && folded.count == min(limit, unranked.count)
        }
    }
}

// MARK: - Missing Instrumentation Diagnostics

enum MissingInstrumentationEntry: CaseIterable, Sendable {
    case syncBool
    case syncExpect
    case asyncBool
    case asyncExpect
}

enum ClosureEffect: CaseIterable, Sendable {
    case synchronous
    case asynchronous
}
