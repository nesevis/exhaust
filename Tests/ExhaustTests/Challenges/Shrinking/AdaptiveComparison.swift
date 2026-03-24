import Testing
@testable import Exhaust

/// Side-by-side comparison of ``StaticStrategy`` vs ``AdaptiveStrategy`` on key generators.
///
/// Each test runs the same generator and seed under both strategies and prints profiling data.
/// The adaptive strategy should produce the same counterexample quality with fewer materializations.
/// Adaptive runs first to avoid warm-cache bias.
@Suite("Adaptive vs Static Comparison")
struct AdaptiveComparisonTests {

    // MARK: - Flat generators (Phase 1 has no structural work)

    @Test("Distinct: flat array, no structural deletions after cycle 1")
    func distinct() {
        let gen = #gen(.int().array(length: 3 ... 30))
        let seed: UInt64 = 5_023_515_172_476_973_421

        var adaptiveReport: ExhaustReport?
        let adaptiveResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .humanOrderPostProcess,
            .replay(seed),
            .adaptiveScheduling,
            .onReport { adaptiveReport = $0 }
        ) {
            Set($0).count < 3
        }

        var staticReport: ExhaustReport?
        let staticResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .humanOrderPostProcess,
            .replay(seed),
            .onReport { staticReport = $0 }
        ) {
            Set($0).count < 3
        }

        printComparison("Distinct", static: staticReport, adaptive: adaptiveReport)
        #expect(staticResult == adaptiveResult)
    }

    @Test("Difference: flat tuple, no structural work")
    func difference() {
        let gen = #gen(.int(in: 0 ... 1000), .int(in: 0 ... 1000), .int(in: 0 ... 1000))
        let seed: UInt64 = 1337

        var adaptiveReport: ExhaustReport?
        let adaptiveResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .adaptiveScheduling,
            .onReport { adaptiveReport = $0 }
        ) { a, b, c in
            b - a < c
        }

        var staticReport: ExhaustReport?
        let staticResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .onReport { staticReport = $0 }
        ) { a, b, c in
            b - a < c
        }

        printComparison("Difference", static: staticReport, adaptive: adaptiveReport)
        #expect(staticResult?.0 == adaptiveResult?.0)
        #expect(staticResult?.1 == adaptiveResult?.1)
        #expect(staticResult?.2 == adaptiveResult?.2)
    }

    @Test("Replacement: flat array, structural work in cycle 1 only")
    func replacement() {
        let gen = #gen(.int(in: 0 ... 100).array(length: 3 ... 10))
        let seed: UInt64 = 1337

        var adaptiveReport: ExhaustReport?
        let adaptiveResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .adaptiveScheduling,
            .onReport { adaptiveReport = $0 }
        ) { arr in
            arr.count < 3 || Set(arr).count == arr.count
        }

        var staticReport: ExhaustReport?
        let staticResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .onReport { staticReport = $0 }
        ) { arr in
            arr.count < 3 || Set(arr).count == arr.count
        }

        printComparison("Replacement", static: staticReport, adaptive: adaptiveReport)
        #expect(staticResult == adaptiveResult)
    }

    // MARK: - Bind generators (Phase 1 has real structural work)

    @Test("Coupling: bind generator, composition edges, structural work throughout")
    func coupling() {
        let gen = #gen(.int(in: 1 ... 8)).bind { n in
            #gen(.int(in: 0 ... n)).array(length: 3)
        }
        let seed: UInt64 = 1337

        var adaptiveReport: ExhaustReport?
        let adaptiveResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .adaptiveScheduling,
            .onReport { adaptiveReport = $0 }
        ) { arr in
            arr.reduce(0, +) < 10
        }

        var staticReport: ExhaustReport?
        let staticResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .onReport { staticReport = $0 }
        ) { arr in
            arr.reduce(0, +) < 10
        }

        printComparison("Coupling", static: staticReport, adaptive: adaptiveReport)
        #expect(staticResult == adaptiveResult)
    }

    @Test("CoupledZeroing: flat generator, zeroingDependency signals")
    func coupledZeroing() {
        let gen = #gen(
            .int(in: 0 ... 20),
            .int(in: 0 ... 20),
            .int(in: 0 ... 20),
            .int(in: 0 ... 20)
        )
        let seed: UInt64 = 42

        var adaptiveReport: ExhaustReport?
        let adaptiveResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .adaptiveScheduling,
            .onReport { adaptiveReport = $0 }
        ) { a, b, c, d in
            a + b < 10 || c + d < 10
        }

        var staticReport: ExhaustReport?
        let staticResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(seed),
            .onReport { staticReport = $0 }
        ) { a, b, c, d in
            a + b < 10 || c + d < 10
        }

        printComparison("CoupledZeroing", static: staticReport, adaptive: adaptiveReport)
        #expect(staticResult?.0 == adaptiveResult?.0)
        #expect(staticResult?.1 == adaptiveResult?.1)
        #expect(staticResult?.2 == adaptiveResult?.2)
        #expect(staticResult?.3 == adaptiveResult?.3)
    }

    // MARK: - Multi-cycle generators (largest potential savings)

    @Test("BinaryHeap: 15 cycles, structural work finishes early")
    func binaryHeap() throws {
        let property: @Sendable (BinaryHeapShrinkingChallenge.Heap<Int>) -> Bool = { heap in
            guard BinaryHeapShrinkingChallenge.invariant(heap) else { return true }
            let xs = BinaryHeapShrinkingChallenge.toSortedList(heap)
            let sorted = BinaryHeapShrinkingChallenge.toList(heap).sorted()
            return sorted == xs.sorted() && xs == xs.sorted()
        }

        let seed: UInt64 = 7_669_171_433_675_367_730

        var adaptiveReport: ExhaustReport?
        let adaptiveResult = try #require(
            #exhaust(
                BinaryHeapShrinkingChallenge.gen,
                .suppressIssueReporting,
                .replay(seed),
                .adaptiveScheduling,
                .onReport { adaptiveReport = $0 },
                property: property
            )
        )

        var staticReport: ExhaustReport?
        let staticResult = try #require(
            #exhaust(
                BinaryHeapShrinkingChallenge.gen,
                .suppressIssueReporting,
                .replay(seed),
                .onReport { staticReport = $0 },
                property: property
            )
        )

        printComparison("BinaryHeap", static: staticReport, adaptive: adaptiveReport)

        let staticValues = BinaryHeapShrinkingChallenge.toList(staticResult)
        let adaptiveValues = BinaryHeapShrinkingChallenge.toList(adaptiveResult)
        #expect(staticValues.count == adaptiveValues.count)
        #expect(staticValues.sorted() == adaptiveValues.sorted())
    }

    @Test("Bound5: multi-cycle, structural work in early cycles only")
    func bound5() {
        struct Bound5: Equatable, Sendable {
            let a: [Int16]
            let b: [Int16]
            let c: [Int16]
            let d: [Int16]
            let e: [Int16]
            let arr: [Int16]
            init(a: [Int16], b: [Int16], c: [Int16], d: [Int16], e: [Int16]) {
                self.a = a
                self.b = b
                self.c = c
                self.d = d
                self.e = e
                arr = a + b + c + d + e
            }
        }

        let arr = #gen(.int16(scaling: .constant).array(length: 0 ... 10, scaling: .constant))
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        let gen = #gen(arr, arr, arr, arr, arr) { a, b, c, d, e in
            Bound5(a: a, b: b, c: c, d: d, e: e)
        }
        let property: @Sendable (Bound5) -> Bool = { b5 in
            if b5.arr.isEmpty { return true }
            return b5.arr.dropFirst().reduce(b5.arr[0], &+) < 5 * 256
        }
        let value = Bound5(
            a: [-18914, -2906, 9816],
            b: [7672, 16087, 24512],
            c: [-11812, -5368, 8526, -24292, 21020, 14344, -1893, -22885],
            d: [25982, 8828, 5007, -6389],
            e: [12744, -11152, -18025, -29069, 30825]
        )

        var adaptiveReport: ExhaustReport?
        let adaptiveResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value),
            .adaptiveScheduling,
            .onReport { adaptiveReport = $0 },
            property: property
        )

        var staticReport: ExhaustReport?
        let staticResult = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value),
            .onReport { staticReport = $0 },
            property: property
        )

        printComparison("Bound5Path1", static: staticReport, adaptive: adaptiveReport)

        #expect(staticResult?.arr.count == adaptiveResult?.arr.count)
        #expect(staticResult?.arr.sorted() == adaptiveResult?.arr.sorted())
    }
}

// MARK: - Helpers

private func printComparison(
    _ name: String,
    static staticReport: ExhaustReport?,
    adaptive adaptiveReport: ExhaustReport?
) {
    let staticMs = staticReport.map { String(format: "%.1fms", $0.reductionMilliseconds) } ?? "n/a"
    let adaptiveMs = adaptiveReport.map { String(format: "%.1fms", $0.reductionMilliseconds) } ?? "n/a"
    let staticMats = staticReport?.totalMaterializations ?? 0
    let adaptiveMats = adaptiveReport?.totalMaterializations ?? 0
    let matsDelta = staticMats - adaptiveMats
    let matsPct = staticMats > 0 ? String(format: "%.0f%%", Double(matsDelta) / Double(staticMats) * 100) : "n/a"

    if let r = staticReport { print("[COMPARE] \(name)(static):   \(staticMs) mats=\(staticMats) \(r.profilingSummary)") }
    if let r = adaptiveReport { print("[COMPARE] \(name)(adaptive): \(adaptiveMs) mats=\(adaptiveMats) (Δ\(matsDelta), \(matsPct)) \(r.profilingSummary)") }
}
