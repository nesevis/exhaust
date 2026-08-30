import Exhaust
import ExhaustCore
import Foundation
import Testing

// The suite drives the guard registry through `resetRegistryForTesting()`, which exists in debug builds only, so the whole suite is absent from a release test build rather than failing to compile it.
#if DEBUG
    /// The guard registry and the thread binding are process-global, so these tests serialize and reset the registry around each use. The test binary is uninstrumented; every guard here is synthetic.
    extension CoverageRegistryTests {
        @Suite("TracePCGuardCoverageSource", .serialized)
        struct TracePCGuardCoverageSourceTests {
            @Test("Uninstrumented process yields no source")
            func uninstrumented() {
                TracePCGuardCoverageSource.resetRegistryForTesting()
                #expect(TracePCGuardCoverageSource.isInstrumented == false)
                #expect(TracePCGuardCoverageSource(harvestsComparisons: false) == nil)
            }

            @Test("Two harvesting trace-pc-guard sources keep their comparison operands apart")
            func comparisonHarvestIsPerSource() {
                TracePCGuardCoverageSource.resetRegistryForTesting()
                let tracePCGuards = TracePCGuardCoverageSource.registerTracePCGuardsForTesting(count: 2)
                defer { tracePCGuards.deallocate() }
                guard let first = TracePCGuardCoverageSource(harvestsComparisons: true),
                      let second = TracePCGuardCoverageSource(harvestsComparisons: true)
                else {
                    Issue.record("expected two trace-pc-guard sources on an instrumented registry")
                    return
                }
                // The first run brackets a property that fires one comparison. A second run in the same process opens its own bracket in between, exactly as a parallel fuzz test in the suite recipe would.
                first.beginAttempt()
                first.beginComparisonCapture()
                TracePCGuardCoverageSource.fireComparisonForTesting(7, 0x5F37_59DF)
                first.endComparisonCapture()
                second.beginAttempt()
                var firstRecords: [(UInt64, UInt64)] = []
                first.forEachComparisonRecord { _, lhs, rhs in
                    firstRecords.append((lhs, rhs))
                }
                first.endAttempt()
                var secondRecords = 0
                second.forEachComparisonRecord { _, _, _ in
                    secondRecords += 1
                }
                second.endAttempt()
                #expect(firstRecords.count == 1, "the first run's operand must survive a second run opening its bracket")
                #expect(firstRecords.first?.1 == 0x5F37_59DF)
                #expect(secondRecords == 0, "the second run must not see the first run's operand")
            }

            @Test("Edges fired on a thread no run owns are counted as off-lane, edges on the run's own unbound lane are not")
            func offLaneHitsAreCounted() async {
                TracePCGuardCoverageSource.resetRegistryForTesting()
                let tracePCGuards = TracePCGuardCoverageSource.registerTracePCGuardsForTesting(count: 2)
                defer { tracePCGuards.deallocate() }
                guard let source = TracePCGuardCoverageSource(harvestsComparisons: false) else {
                    Issue.record("expected a trace-pc-guard source on an instrumented registry")
                    return
                }
                // One bracket on this thread makes it the run's lane. Between brackets the lane is unbound by design, and edges it fires there are excluded, not lost.
                source.beginAttempt()
                source.endAttempt()
                let before = source.offLaneHitCount
                TracePCGuardCoverageSource.fireTracePCGuardForTesting(tracePCGuards)
                #expect(source.offLaneHitCount == before, "the run's own lane between brackets is excluded by design")

                // A thread the run never bound is where main-actor and custom-executor work lands; its edges are the loss the report must name.
                // Foundation's Thread block is @Sendable on Linux; the pointer outlives the thread (deallocated after the await) and only the worker touches it.
                nonisolated(unsafe) let offLaneTracePCGuard = tracePCGuards + 1
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let worker = Thread {
                        TracePCGuardCoverageSource.fireTracePCGuardForTesting(offLaneTracePCGuard)
                        TracePCGuardCoverageSource.fireTracePCGuardForTesting(offLaneTracePCGuard)
                        continuation.resume()
                    }
                    worker.start()
                }
                #expect(source.offLaneHitCount == before + 2)
            }

            @Test("Claiming the lane excludes pre-bracket edges on it without binding a context")
            func claimLaneExcludesPreBracketEdges() {
                TracePCGuardCoverageSource.resetRegistryForTesting()
                let tracePCGuards = TracePCGuardCoverageSource.registerTracePCGuardsForTesting(count: 1)
                defer { tracePCGuards.deallocate() }
                guard let source = TracePCGuardCoverageSource(harvestsComparisons: false) else {
                    Issue.record("expected a trace-pc-guard source on an instrumented registry")
                    return
                }
                // The runner's screening prologue: the generator runs on the run's lane before the first bracket ever opens.
                let before = source.offLaneHitCount
                source.claimLane()
                TracePCGuardCoverageSource.fireTracePCGuardForTesting(tracePCGuards)
                #expect(source.offLaneHitCount == before)
                #expect(source.isBoundOnCurrentThread == false, "claiming is not binding: nothing records until a bracket opens")
            }

            @Test("A guard fired 128 or more times reports exactly 128")
            func hitCountSaturatesAtOneTwentyEight() {
                let gen = #gen(.int(in: 128 ... 5000))
                #exhaust(gen) { repeatCount in
                    TracePCGuardCoverageSource.resetRegistryForTesting()
                    let tracePCGuards = TracePCGuardCoverageSource.registerTracePCGuardsForTesting(count: 1)
                    defer { tracePCGuards.deallocate() }
                    guard let source = TracePCGuardCoverageSource(harvestsComparisons: false) else {
                        Issue.record("expected a trace-pc-guard source on an instrumented registry")
                        return
                    }
                    source.beginAttempt()
                    for _ in 0 ..< repeatCount {
                        TracePCGuardCoverageSource.fireTracePCGuardForTesting(tracePCGuards)
                    }
                    var reported: [(edge: Int, hitCount: UInt8)] = []
                    source.forEachHitEdge { edge, hitCount in
                        reported.append((edge, hitCount))
                    }
                    source.endAttempt()
                    #expect(reported.count == 1)
                    #expect(reported.first?.hitCount == 128)
                }
            }

            @Test("Hit edges are reported in first-hit order with counts saturating at 128")
            func hitsReportFirstHitOrderAndSaturatingCounts() {
                let tracePCGuardCount = 8
                // Each burst repeats one guard up to 300 times, so a single burst carries a guard past the saturation cap by construction.
                let burstGen = #gen(.int(in: 0 ... tracePCGuardCount - 1), .int(in: 1 ... 300)) { tracePCGuardIndex, repeatCount in
                    TracePCGuardBurst(tracePCGuardIndex: tracePCGuardIndex, repeatCount: repeatCount)
                }
                let gen = #gen(burstGen.array(length: 0 ... 12))
                #exhaust(gen, .budget(.extensive)) { bursts in
                    let fixture = TracePCGuardFixture(count: tracePCGuardCount)
                    defer { fixture.tearDown() }
                    fixture.source.beginAttempt()
                    for burst in bursts {
                        for _ in 0 ..< burst.repeatCount {
                            fixture.fire(burst.tracePCGuardIndex)
                        }
                    }

                    var expectedOrder: [Int] = []
                    var expectedCounts: [Int: Int] = [:]
                    for burst in bursts {
                        if expectedCounts[burst.tracePCGuardIndex] == nil {
                            expectedOrder.append(burst.tracePCGuardIndex)
                        }
                        expectedCounts[burst.tracePCGuardIndex, default: 0] += burst.repeatCount
                    }
                    let reported = fixture.reportedHits()
                    #expect(reported.map(\.edge) == expectedOrder)
                    for (edge, hitCount) in reported {
                        #expect(Int(hitCount) == min(expectedCounts[edge] ?? 0, 128))
                    }
                }
            }

            @Test("Reset clears the previous attempt without leaking into the next")
            func resetIsolatesAttempts() {
                let tracePCGuardCount = 6
                let gen = #gen(
                    .int(in: 0 ... tracePCGuardCount - 1).array(length: 0 ... 40),
                    .int(in: 0 ... tracePCGuardCount - 1).array(length: 0 ... 40)
                )
                #exhaust(gen) { firstAttempt, secondAttempt in
                    let fixture = TracePCGuardFixture(count: tracePCGuardCount)
                    defer { fixture.tearDown() }
                    fixture.source.beginAttempt()
                    for tracePCGuardIndex in firstAttempt {
                        fixture.fire(tracePCGuardIndex)
                    }
                    fixture.source.beginAttempt()
                    for tracePCGuardIndex in secondAttempt {
                        fixture.fire(tracePCGuardIndex)
                    }
                    let reported = fixture.reportedHits()
                    #expect(Set(reported.map(\.edge)) == Set(secondAttempt))
                    #expect(reported.map(\.hitCount).reduce(0) { $0 + Int($1) } == secondAttempt.count)
                }
            }

            @Test("Edges fired on an unbound thread are dropped, not misattributed")
            func unboundThreadDropsEdges() async {
                let fixture = TracePCGuardFixture(count: 4)
                defer { fixture.tearDown() }
                fixture.source.beginAttempt()
                #expect(fixture.source.isBoundOnCurrentThread)
                // Fired before the suspension, because the binding belongs to this thread and the continuation may resume elsewhere.
                fixture.fire(3)

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let worker = Thread {
                        fixture.fire(1)
                        fixture.fire(2)
                        continuation.resume()
                    }
                    worker.start()
                }

                #expect(fixture.reportedHits().map(\.edge) == [3])
            }

            @Test("Trace-pc-guards outside the registered range and the unassigned id zero are ignored")
            func outOfRangeTracePCGuardsAreIgnored() {
                let fixture = TracePCGuardFixture(count: 3)
                defer { fixture.tearDown() }
                fixture.source.beginAttempt()
                var zeroTracePCGuard: UInt32 = 0
                var oversizedTracePCGuard: UInt32 = 99
                TracePCGuardCoverageSource.fireTracePCGuardForTesting(&zeroTracePCGuard)
                TracePCGuardCoverageSource.fireTracePCGuardForTesting(&oversizedTracePCGuard)
                fixture.fire(0)
                #expect(fixture.reportedHits().map(\.edge) == [0])
            }
        }
    }

    // MARK: - Supporting Types

    private struct TracePCGuardBurst: Sendable {
        var tracePCGuardIndex: Int
        var repeatCount: Int
    }

    // MARK: - Helpers

    /// One registered trace-pc-guard image and a source over it. Trace-pc-guard ids are assigned 1-based by the init callback and reported 0-based by the source, so `fire(index)` and the reported edge agree.
    ///
    /// Construction resets the process-global registry, so two fixtures must never be alive at once. The `.serialized` suite covers tests, and the property tests here rely on `#exhaust` running single-lane: passing `.parallelize` to either would let two invocations reset each other's tracePCGuards mid-attempt.
    private final class TracePCGuardFixture: @unchecked Sendable {
        let source: TracePCGuardCoverageSource
        private let tracePCGuards: UnsafeMutablePointer<UInt32>
        private let count: Int

        init(count: Int) {
            TracePCGuardCoverageSource.resetRegistryForTesting()
            self.count = count
            tracePCGuards = TracePCGuardCoverageSource.registerTracePCGuardsForTesting(count: count)
            guard let source = TracePCGuardCoverageSource(harvestsComparisons: false) else {
                fatalError("registering \(count) tracePCGuards must yield a source")
            }
            self.source = source
        }

        func fire(_ index: Int) {
            precondition(index >= 0 && index < count)
            TracePCGuardCoverageSource.fireTracePCGuardForTesting(tracePCGuards + index)
        }

        func reportedHits() -> [(edge: Int, hitCount: UInt8)] {
            var hits: [(edge: Int, hitCount: UInt8)] = []
            source.forEachHitEdge { edge, hitCount in
                hits.append((edge, hitCount))
            }
            return hits
        }

        func tearDown() {
            TracePCGuardCoverageSource.resetRegistryForTesting()
            tracePCGuards.deallocate()
        }
    }
#endif
