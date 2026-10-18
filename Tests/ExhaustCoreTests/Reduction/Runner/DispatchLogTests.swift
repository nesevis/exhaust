//
//  DispatchLogTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Dispatch Log Tests

/// Pins the per-dispatch instrumentation: one ``DispatchRecord`` per completed encoder pass, ordered, and consistent with the aggregate per-encoder counters.
@Suite("Dispatch log")
struct DispatchLogTests {
    @Test("Log stays empty in stats-collecting runs unless the maintainer flag is set")
    func logStaysEmptyWithoutMaintainerFlag() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100),
            Gen.choose(in: UInt64(0) ... 100)
        )
        let property: ((UInt64, UInt64)) -> Bool = { pair in
            pair.0 < 10 || pair.1 < 10
        }

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 7, maxRuns: 500)
        var found: ((UInt64, UInt64), ChoiceTree)?
        while let pair = try iterator.next() {
            if property(pair.0) == false {
                found = pair
                break
            }
        }
        let (value, tree) = try #require(found)

        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            property: property
        )

        #expect(result.stats.dispatchLog.isEmpty)
    }
}
