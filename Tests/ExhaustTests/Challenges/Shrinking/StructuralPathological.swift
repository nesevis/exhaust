//
//  StructuralPathological.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Structural Pathological")
struct StructuralPathologicalChallenge {
    /*
     Tests for pathological generator STRUCTURES rather than pathological properties.
     The standard shrinking challenges use mostly flat generators (arrays, tuples,
     recursive trees) — their CDGs have zero or very few composition edges. These tests
     exercise bind-dependent generators with non-trivial CDG topologies: nested binds,
     wide independent binds, threshold-crossing fibres, and cross-level coupling.

     Purpose: provide profiling data for the reduction planning decision tree,
     specifically for composition edges, encoder selection, fibre threshold crossing,
     convergence transfer, and multi-level bind coordination.
     */

    // MARK: - Fibre Threshold Crossing

    @Test("Fibre threshold crossing")
    func fibreThresholdCrossing() {
        // Single bind: n in 1...8, 3-element array with elements in 0...n.
        // Fibre sizes: n=3 → 4³=64 (exhaustive boundary), n=4 → 5³=125 (pairwise).
        // Property passes when max element < 5; fails when max >= 5 AND sum >= 10.
        // Smallest n where failure is possible: n=5 (elements can reach 5, and 0+5+5=10).
        let gen = #gen(.int(in: 1 ... 8)).bind { n in
            #gen(.int(in: 0 ... n)).array(length: 3)
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(1337),
            .onReport { report = $0 }
        ) { arr in
            (arr.max() ?? 0) < 5 || arr.reduce(0, +) < 10
        }
        if let report { print("[PROFILE] FibreThreshold: \(report.profilingSummary)") }

        #expect(output == [0, 5, 5])
    }

    // MARK: - Cross-Level Sum (composition required)

    @Test("Cross-level sum constraint")
    func crossLevelSum() {
        // Single bind: n in 2...10, 3-element array with elements in 0...n.
        // Property: arr[0] > 0 AND arr[1] > 0 AND arr[2] == arr[0] + arr[1] → fails.
        // Phase 2 gets stuck: reducing any single coordinate breaks the sum constraint.
        // Composition jointly reduces n and searches the fibre at n=2 (fibre=3³=27,
        // exhaustive): the only failing case is [1, 1, 2].
        let gen = #gen(.int(in: 2 ... 10)).bind { n in
            #gen(.int(in: 0 ... n)).array(length: 3)
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(1337),
            .onReport { report = $0 }
        ) { arr in
            arr[0] == 0 || arr[1] == 0 || arr[2] != arr[0] + arr[1]
        }
        if let report { print("[PROFILE] CrossLevelSum: \(report.profilingSummary)") }

        #expect(output == [1, 1, 2])
    }

    // MARK: - Nested Bind: Two Levels

    @Test("Nested bind, two levels")
    func nestedBindTwoLevel() {
        // Two-level bind: a in 1...6, b in 1...a, 2-element array in 0...(a*b).
        // CDG has 2 edges in topological order (outer before inner).
        // Property: sum < 8. Fails when sum >= 8.
        // Smallest (a, b): a=2, b=2 → range 0...4, [4, 4]=8.
        let gen = #gen(.int(in: 1 ... 6)).bind { a in
            #gen(.int(in: 1 ... a)).bind { b in
                #gen(.int(in: 0 ... (a * b))).array(length: 2)
            }
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(1337),
            .onReport { report = $0 }
        ) { arr in
            arr.reduce(0, +) < 8
        }
        if let report { print("[PROFILE] NestedBind2: \(report.profilingSummary)") }

        #expect(output == [4, 4])
    }

    // MARK: - Nested Bind: Three Levels

    @Test("Nested bind, three levels")
    func nestedBindThreeLevel() {
        // Three-level bind: a in 1...4, b in 1...a, c in 1...b, scalar in 0...(a+b+c).
        // CDG has 3 edges. Deepest nesting in the test suite.
        // Property: value < 6. Fails when value >= 6.
        // Smallest (a, b, c) with a+b+c >= 6: (2, 2, 2) → range 0...6, value=6.
        let gen = #gen(.int(in: 1 ... 4)).bind { a in
            #gen(.int(in: 1 ... a)).bind { b in
                #gen(.int(in: 1 ... b)).bind { c in
                    #gen(.int(in: 0 ... (a + b + c)))
                }
            }
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(1337),
            .onReport { report = $0 }
        ) { value in
            value < 6
        }
        if let report { print("[PROFILE] NestedBind3: \(report.profilingSummary)") }

        #expect(output == 6)
    }

    // MARK: - Wide CDG: Independent Binds

    @Test("Wide CDG with independent binds")
    func wideIndependentBinds() {
        // Two independent bind edges at the same level (wide CDG, not deep).
        // genA: a in 1...8, x in 0...a. genB: b in 1...8, y in 0...b.
        // CDG has 2 independent edges — exercises parallel edge processing.
        // Property: x + y < 10. Fails when x + y >= 10.
        // Per-coordinate reduction converges to a local minimum because reducing a
        // (which clamps x) requires increasing b to compensate — cross-edge coordination
        // that the current reducer does not perform.
        let gen = #gen(
            #gen(.int(in: 1 ... 8)).bind { a in #gen(.int(in: 0 ... a)) },
            #gen(.int(in: 1 ... 8)).bind { b in #gen(.int(in: 0 ... b)) }
        )

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(1337),
            .onReport { report = $0 }
        ) { x, y in
            x + y < 10
        }
        if let report { print("[PROFILE] WideCDG: \(report.profilingSummary)") }

        #expect(output?.0 == 3)
        #expect(output?.1 == 7)
    }

    // MARK: - Multi-Parameter Fibre

    @Test("Multi-parameter fibre")
    func multiParameterFibre() {
        // Single bind: n in 1...5, 5-element array with elements in 0...n.
        // Fibre sizes: n=1 → 2⁵=32 (exhaustive), n=3 → 4⁵=1024 (pairwise, ~80 IPOG rows).
        // Exercises IPOG pairwise covering array generation with many parameters.
        // Property: sum < 12. Fails when sum >= 12.
        // Smallest n where failure possible: n=3. Per-coordinate reduction converges to a
        // local minimum where each element is at its floor — sum equals 12 but the
        // distribution across elements is seed-dependent.
        let gen = #gen(.int(in: 1 ... 5)).bind { n in
            #gen(.int(in: 0 ... n)).array(length: 5)
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(1337),
            .onReport { report = $0 }
        ) { arr in
            arr.reduce(0, +) < 12
        }
        if let report { print("[PROFILE] MultiParamFibre: \(report.profilingSummary)") }

        #expect(output?.reduce(0, +) == 12)
    }

    // MARK: - Non-Monotonic Fibre

    @Test("Non-monotonic fibre size", .disabled())
    func nonMonotonicFibre() {
        // Single bind with non-monotonic fibre: domain peaks at n=3 (range 0...9, fibre=100),
        // then shrinks (n=5 → range 0...7, fibre=64; n=8 → range 0...4, fibre=25).
        // Exercises encoder selection when reducing upstream does NOT monotonically reduce fibre.
        // Property: sum < 8. Fails when sum >= 8.
        // Smallest n where failure possible: n=2 (range 0...6).
        // Per-coordinate reduction converges to equal-valued pair [4, 4] — the global
        // minimum [2, 6] requires cross-coordinate redistribution.
        let gen = #gen(.int(in: 0 ... 8)).bind { n in
            #gen(.int(in: 0 ... (n < 4 ? n * 3 : 12 - n))).array(length: 2)
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(1337),
            .onReport { report = $0 }
        ) { arr in
            arr[0] + arr[1] < 8
        }
        if let report { print("[PROFILE] NonMonotonicFibre: \(report.profilingSummary)") }

        #expect(output == [4, 4])
    }

    // MARK: - Varying Edge Productivity

    @Test("Varying edge productivity across CDG edges")
    func varyingEdgeProductivity() {
        // Two independent binds with different downstream fibre sizes.
        // Edge 1: a in 1...6, 2-element array in 0...a. Fibre at a=6: 7²=49 (exhaustive, productive).
        // Edge 2: b in 1...6, 8-element array in 0...b. Fibre at b=6: 7⁸=5.7M (too large, futile under fixed budget).
        // Property: sum of all elements >= 15.
        // Edge 1 is productive (small fibre, failures findable). Edge 2 is futile (fibre too
        // large for covering or exhaustive, only ZeroValue fallback via DownstreamPick).
        // Adaptive per-edge budget would give more to edge 1 and less to edge 2.
        let gen = #gen(
            #gen(.int(in: 1 ... 6)).bind { a in #gen(.int(in: 0 ... a)).array(length: 2) },
            #gen(.int(in: 1 ... 6)).bind { b in #gen(.int(in: 0 ... b)).array(length: 8) }
        )

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(42),
            .onReport { report = $0 }
        ) { small, large in
            small.reduce(0, +) + large.reduce(0, +) < 15
        }
        if let report { print("[PROFILE] VaryingEdgeProductivity: \(report.profilingSummary)") }

        let total = (output?.0.reduce(0, +) ?? 0) + (output?.1.reduce(0, +) ?? 0)
        #expect(total >= 15)
    }

    // MARK: - Exhaustible Edges

    @Test("Edges that become exhaustedClean after initial exploration")
    func exhaustibleEdges() {
        // Single bind: n in 1...10, 2-element array in 0...n.
        // Property: fails only when n >= 5 AND both elements equal n (the maximum).
        // At n=5: fibre is 6²=36 (exhaustive). The only failure is [5, 5].
        // After composition reduces n to 5 and finds [5, 5], Phase 2 settles values.
        // Subsequent cycles: the fibre at n=5 has been fully searched and found its
        // only failure. The edge should be exhaustedClean at n=5 for values below [5, 5]
        // — no point re-exploring.
        let gen = #gen(.int(in: 1 ... 10)).bind { n in
            #gen(.int(in: 0 ... n)).array(length: 2)
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(42),
            .onReport { report = $0 }
        ) { arr in
            arr.max() != arr.count || arr.min() != arr.max()
        }
        if let report { print("[PROFILE] ExhaustibleEdges: \(report.profilingSummary)") }

        // The minimum counterexample: both elements at the bind-inner value, and that
        // value is the smallest n where the property fails.
        #expect(output != nil)
    }

    // MARK: - Coupled Zeroing

    @Test("Coupled coordinates where batch zeroing fails but individual succeeds")
    func coupledZeroing() {
        // Flat generator: 4 integers in 0...20.
        // Property: fails when a + b >= 10 AND c + d >= 10.
        // Batch zeroing all four to zero passes the property (0+0 < 10 for both pairs).
        // Individual zeroing of a succeeds if b is large enough (b >= 10).
        // This produces zeroingDependency signals — the coordinates are coupled through
        // the sum constraint. Redistribution (Phase 4) is the natural recovery path.
        let gen = #gen(
            .int(in: 0 ... 20),
            .int(in: 0 ... 20),
            .int(in: 0 ... 20),
            .int(in: 0 ... 20)
        )

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(42),
            .onReport { report = $0 }
        ) { a, b, c, d in
            a + b < 10 || c + d < 10
        }
        if let report { print("[PROFILE] CoupledZeroing: \(report.profilingSummary)") }

        // Minimum: both pairs sum to exactly 10. Shortlex-smallest is (0, 10, 0, 10).
        if let output {
            #expect(output.0 + output.1 >= 10)
            #expect(output.2 + output.3 >= 10)
        }
    }

    // MARK: - Fibre Descent Gate

    @Test("Fibre descent gate fires after Phase 2 convergence")
    func fibreDescentGate() {
        // Flat 10-element unsigned array, no bind. Phase 2 converges all coordinates,
        // then stalls. No composition (edges=0) so the convergence cache stays stable across
        // stall cycles. With .slow budget (maxStalls=8), the gate fires on stall cycle 2+,
        // saving Phase 2's re-confirmation probes (ZeroValue all-at-once + individual probes).
        let gen = #gen(.uint(in: 0 ... 100)).array(length: 10)

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
//            .randomOnly,
            .replay(12_791_394_592_254_154_946),
            .budget(.expedient),
            .onReport { report = $0 }
        ) { arr in
            arr.reduce(0, +) < 50
        }
        if let report { print("[PROFILE] FibreDescentGate: \(report.profilingSummary)") }

        // Minimum: sum == 50 with smallest shortlex. All values at floor.
        #expect(output?.reduce(0, +) == 50)
    }
}
