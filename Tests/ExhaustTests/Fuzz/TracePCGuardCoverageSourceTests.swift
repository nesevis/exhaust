import Exhaust
import ExhaustCore
import Foundation
import Testing

// The suite drives the guard registry through `resetRegistryForTesting()`, which exists in debug builds only, so the whole suite is absent from a release test build rather than failing to compile it.
#if DEBUG
    /// The guard registry and the thread binding are process-global, so these tests serialize and reset the registry around each use. The test binary is uninstrumented; every guard here is synthetic.
    @Suite("TracePCGuardCoverageSource", .serialized)
    struct TracePCGuardCoverageSourceTests {
        @Test("Uninstrumented process yields no source")
        func uninstrumented() {
            TracePCGuardCoverageSource.resetRegistryForTesting()
            #expect(TracePCGuardCoverageSource.isInstrumented == false)
            #expect(TracePCGuardCoverageSource(harvestsComparisons: false) == nil)
        }

        @Test("Hit edges are reported in first-hit order with counts saturating at 128")
        func hitsReportFirstHitOrderAndSaturatingCounts() {
            let guardCount = 8
            // Each burst repeats one guard up to 300 times, so a single burst carries a guard past the saturation cap by construction.
            let burstGen = #gen(.int(in: 0 ... guardCount - 1), .int(in: 1 ... 300)) { guardIndex, repeatCount in
                GuardBurst(guardIndex: guardIndex, repeatCount: repeatCount)
            }
            let gen = #gen(burstGen.array(length: 0 ... 12))
            #exhaust(gen, .budget(.extensive)) { bursts in
                let fixture = GuardFixture(count: guardCount)
                defer { fixture.tearDown() }
                fixture.source.beginAttempt()
                for burst in bursts {
                    for _ in 0 ..< burst.repeatCount {
                        fixture.fire(burst.guardIndex)
                    }
                }

                var expectedOrder: [Int] = []
                var expectedCounts: [Int: Int] = [:]
                for burst in bursts {
                    if expectedCounts[burst.guardIndex] == nil {
                        expectedOrder.append(burst.guardIndex)
                    }
                    expectedCounts[burst.guardIndex, default: 0] += burst.repeatCount
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
            let guardCount = 6
            let gen = #gen(
                .int(in: 0 ... guardCount - 1).array(length: 0 ... 40),
                .int(in: 0 ... guardCount - 1).array(length: 0 ... 40)
            )
            #exhaust(gen) { firstAttempt, secondAttempt in
                let fixture = GuardFixture(count: guardCount)
                defer { fixture.tearDown() }
                fixture.source.beginAttempt()
                for guardIndex in firstAttempt {
                    fixture.fire(guardIndex)
                }
                fixture.source.beginAttempt()
                for guardIndex in secondAttempt {
                    fixture.fire(guardIndex)
                }
                let reported = fixture.reportedHits()
                #expect(Set(reported.map(\.edge)) == Set(secondAttempt))
                #expect(reported.map(\.hitCount).reduce(0) { $0 + Int($1) } == secondAttempt.count)
            }
        }

        @Test("Edges fired on an unbound thread are dropped, not misattributed")
        func unboundThreadDropsEdges() async {
            let fixture = GuardFixture(count: 4)
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

        @Test("Guards outside the registered range and the unassigned id zero are ignored")
        func outOfRangeGuardsAreIgnored() {
            let fixture = GuardFixture(count: 3)
            defer { fixture.tearDown() }
            fixture.source.beginAttempt()
            var zeroGuard: UInt32 = 0
            var oversizedGuard: UInt32 = 99
            TracePCGuardCoverageSource.fireGuardForTesting(&zeroGuard)
            TracePCGuardCoverageSource.fireGuardForTesting(&oversizedGuard)
            fixture.fire(0)
            #expect(fixture.reportedHits().map(\.edge) == [0])
        }
    }

    // MARK: - Supporting Types

    private struct GuardBurst: Sendable {
        var guardIndex: Int
        var repeatCount: Int
    }

    // MARK: - Helpers

    /// One registered guard image and a source over it. Guard ids are assigned 1-based by the init callback and reported 0-based by the source, so `fire(index)` and the reported edge agree.
    ///
    /// Construction resets the process-global registry, so two fixtures must never be alive at once. The `.serialized` suite covers tests, and the property tests here rely on `#exhaust` running single-lane: passing `.parallelize` to either would let two invocations reset each other's guards mid-attempt.
    private final class GuardFixture: @unchecked Sendable {
        let source: TracePCGuardCoverageSource
        private let guards: UnsafeMutablePointer<UInt32>
        private let count: Int

        init(count: Int) {
            TracePCGuardCoverageSource.resetRegistryForTesting()
            self.count = count
            guards = TracePCGuardCoverageSource.registerGuardsForTesting(count: count)
            guard let source = TracePCGuardCoverageSource(harvestsComparisons: false) else {
                fatalError("registering \(count) guards must yield a source")
            }
            self.source = source
        }

        func fire(_ index: Int) {
            precondition(index >= 0 && index < count)
            TracePCGuardCoverageSource.fireGuardForTesting(guards + index)
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
            guards.deallocate()
        }
    }
#endif
