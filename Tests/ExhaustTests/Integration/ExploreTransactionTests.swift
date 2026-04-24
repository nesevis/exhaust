import Testing
@testable import Exhaust

// MARK: - Helpers

private func asArray(_ tuple: (Int, Int, Int, Int, Int, Int, Int, Int)) -> [Int] {
    [tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7]
}

private func runningMin(_ transactions: [Int]) -> Int {
    var balance = 0
    var minimum = 0
    for transaction in transactions {
        balance += transaction
        minimum = min(minimum, balance)
    }
    return minimum
}

private func dipsAndRecovers(_ transactions: [Int]) -> Bool {
    var balance = 0
    var dipped = false
    for transaction in transactions {
        balance += transaction
        if balance < 0 { dipped = true }
    }
    return dipped && balance >= 0
}

private func makeTransactionDirections() -> [(String, @Sendable ((Int, Int, Int, Int, Int, Int, Int, Int)) -> Bool)] {
    [
        ("all deposits", { t in asArray(t).allSatisfy { $0 >= 0 } }),
        ("all withdrawals", { t in asArray(t).allSatisfy { $0 <= 0 } }),
        ("dips and recovers", { t in dipsAndRecovers(asArray(t)) }),
        ("deep dip (below -200)", { t in runningMin(asArray(t)) < -200 }),
        ("net zero", { t in asArray(t).reduce(0, +) == 0 }),
        ("large swing", { t in asArray(t).contains { abs($0) > 80 } }),
    ]
}

// MARK: - Tests

@Suite("#explore: transaction sequence coverage")
struct ExploreTransactionTests {
    @Test("All reachable directions achieve coverage")
    func allReachableDirectionsAchieveCoverage() {
        let gen = #gen(
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100)
        )

        let report = #explore(
            gen,
            .budget(.expensive),
            .suppress(.all),
            directions: [
                ("dips and recovers", { t in dipsAndRecovers(asArray(t)) }),
                ("deep dip (below -200)", { t in runningMin(asArray(t)) < -200 }),
                ("large swing", { t in asArray(t).contains { abs($0) > 80 } }),
            ]
        ) { _ in
            true
        }

        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)

        for entry in report.directionCoverage {
            #expect(entry.isCovered, "Direction '\(entry.name)' was not covered")
        }
    }

    @Test("CGS steers into 'dips and recovers' despite low natural prevalence")
    func dipDirectionGetsSteeredCoverage() {
        let gen = #gen(
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100)
        )

        let report = #explore(
            gen,
            .budget(.expensive),
            .suppress(.all),
            directions: makeTransactionDirections()
        ) { _ in
            true
        }

        let dipEntry = report.directionCoverage
            .first { $0.name == "dips and recovers" }!
        #expect(dipEntry.isCovered, "CGS should steer enough samples into the dip-and-recover region")

        let warmupHitRate = Double(dipEntry.warmupHits) / Double(report.warmupSamples)
        #expect(warmupHitRate < 0.5, "Dip-and-recover should be uncommon in untuned sampling (got \(warmupHitRate))")
    }

    @Test("Co-occurrence: 'all deposits' and 'dips and recovers' are mutually exclusive")
    func allDepositsAndDipAreMutuallyExclusive() {
        let gen = #gen(
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100),
            .int(in: -100 ... 100), .int(in: -100 ... 100)
        )

        let report = #explore(
            gen,
            .budget(.exorbitant),
            .suppress(.all),
            directions: makeTransactionDirections()
        ) { _ in
            true
        }

        let allDepositsIndex = 0
        let dipsIndex = 2
        let overlap = report.coOccurrence.count(direction: allDepositsIndex, direction: dipsIndex)
        #expect(overlap == 0, "'All deposits' and 'dips and recovers' should never co-occur")
    }
}
