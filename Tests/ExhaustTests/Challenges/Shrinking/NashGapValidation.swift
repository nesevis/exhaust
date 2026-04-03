import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Nash-Gap Validation")
struct NashGapValidation {

    // MARK: - Mixed coupling: coupled pairs + independent high-value coordinates

    // 8 integers: a,b coupled (sum >= 10), c,d coupled (sum >= 10),
    // e,f,g,h independent (each must be >= 15).
    //
    // After fibre descent:
    //   e,f,g,h converge to 15 independently (monotoneConvergence, high distance ~30 zigzag)
    //   a,b converge to ~5,5 but can't be zeroed individually (zeroingDependency)
    //   c,d same
    //
    // Old sort: orders by lhs distance descending. e,f,g,h (distance ~30) dominate,
    // so the relax-round wastes probes trying to redistribute FROM e/f/g/h
    // (which fails because zeroing them breaks the >= 15 constraint).
    //
    // Nash-gap tier sort: pairs (a,b) and (c,d) (both-coupled tier) come before
    // any pair involving e/f/g/h (no dependency signal), finding productive
    // redistributions in fewer probes.
    @Test("Mixed coupling — coupled pairs among independent high-value coordinates")
    func mixedCoupling() {
        let gen = #gen(
            .int(in: 0 ... 30),
            .int(in: 0 ... 30),
            .int(in: 0 ... 30),
            .int(in: 0 ... 30),
            .int(in: 0 ... 30),
            .int(in: 0 ... 30),
            .int(in: 0 ... 30),
            .int(in: 0 ... 30)
        )

        // Large counterexample where all constraints are satisfied.
        let value = (18, 22, 15, 25, 28, 19, 27, 20)

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value),
            .onReport { report = $0 },
            .logging(.debug)
        ) { a, b, c, d, e, f, g, h in
            // Fails when: both coupled sums >= 10 AND all four independent values >= 15.
            a + b < 10 || c + d < 10 || e < 15 || f < 15 || g < 15 || h < 15
        }
        if let report { print("[PROFILE] MixedCoupling: \(report.profilingSummary)") }

        if let output {
            #expect(output.0 + output.1 >= 10)
            #expect(output.2 + output.3 >= 10)
            #expect(output.4 >= 15)
            #expect(output.5 >= 15)
            #expect(output.6 >= 15)
            #expect(output.7 >= 15)
        }
    }

    // MARK: - Wide mixed coupling (reflected)

    // 10 integers: 3 coupled pairs (sum >= 8 each) + 4 independent (each >= 20).
    // More coordinates = more wasted probes on independent-to-independent pairs
    // without tier-based sorting.
    @Test("Wide mixed coupling — 3 coupled pairs + 4 independent")
    func wideMixedCoupling() {
        let gen = #gen(
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40),
            .int(in: 0 ... 40)
        )

        let value = (12, 28, 19, 35, 8, 27, 38, 22, 31, 25)

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value),
            .onReport { report = $0 },
            .logging(.debug)
        ) { a, b, c, d, e, f, g, h, i, j in
            a + b < 8 || c + d < 8 || e + f < 8 || g < 20 || h < 20 || i < 20 || j < 20
        }
        if let report { print("[PROFILE] WideMixedCoupling: \(report.profilingSummary)") }

        if let output {
            #expect(output.0 + output.1 >= 8)
            #expect(output.2 + output.3 >= 8)
            #expect(output.4 + output.5 >= 8)
            #expect(output.6 >= 20)
            #expect(output.7 >= 20)
            #expect(output.8 >= 20)
            #expect(output.9 >= 20)
        }
    }
}
