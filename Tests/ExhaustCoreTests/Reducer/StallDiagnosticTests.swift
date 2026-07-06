//
//  StallDiagnosticTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Stall Diagnostic Tests

/// Pins the silent-stall diagnostic: a run that never accepts while leaves sit converged short of their targets reports the stall, and both halves of the warning condition stay quiet on healthy runs.
@Suite("Stall diagnostic")
struct StallDiagnosticTests {
    @Test("A fully stalled run reports stalled leaves and no acceptance")
    func fullyStalledRunReportsStall() throws {
        // A 2:1 ratio coupling with the relation encoder excluded: every single-value move, sum-conserving exchange, and lockstep shift breaks the coupling, so the reducer can accept nothing.
        let stats = try reduceCollectingStats(
            gen: ratioGen,
            property: ratioProperty,
            enabledEncoders: Set(EncoderName.allCases).subtracting([.relationSearch])
        )

        #expect(stats.anyAcceptanceEverOccurred == false)
        #expect(stats.stalledLeafCount >= 1)
        #expect(stats.stalledLeafResidualDistance > 0)
    }

    @Test("The relation encoder resolves the same coupling, so no stall is reported")
    func relationSearchClearsTheStall() throws {
        let stats = try reduceCollectingStats(
            gen: ratioGen,
            property: ratioProperty,
            enabledEncoders: nil
        )

        #expect(stats.anyAcceptanceEverOccurred)
    }

    @Test("Stalled leaves on an accepting run do not meet the warning condition")
    func acceptingRunWithResidualLeavesIsNotAStall() throws {
        // Both coordinates reduce to 10 and stay short of their target of 1: stalled leaves are normal at the end of a successful reduction, and the acceptance flag is what separates them from a silent stall.
        let gen = Gen.zip(
            Gen.choose(in: UInt64(1) ... 100),
            Gen.choose(in: UInt64(1) ... 100)
        )
        let property: @Sendable ((UInt64, UInt64)) -> Bool = { pair in
            pair.0 < 10 || pair.1 < 10
        }
        let stats = try reduceCollectingStats(gen: gen, property: property, enabledEncoders: nil)

        #expect(stats.anyAcceptanceEverOccurred)
        #expect(stats.stalledLeafCount >= 1)
    }
}

// MARK: - Helpers

private let ratioGen = Gen.zip(
    Gen.choose(in: UInt64(1) ... 20),
    Gen.choose(in: UInt64(1) ... 10)
)

private let ratioProperty: @Sendable ((UInt64, UInt64)) -> Bool = { pair in
    pair.0 != 2 &* pair.1
}

private func reduceCollectingStats<Output>(
    gen: Generator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    enabledEncoders: Set<EncoderName>?
) throws -> ReductionStats {
    var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 5, maxRuns: 5000)
    var found: (Output, ChoiceTree)?
    while let pair = try iterator.next() {
        if property(pair.0) == false {
            found = pair
            break
        }
    }
    let (value, tree) = try #require(found)

    var machine = ReductionMachine(
        gen: gen,
        initialTree: tree,
        initialOutput: value,
        config: Interpreters.ReducerConfiguration(maxStalls: 3, enabledEncoders: enabledEncoders),
        collectStats: true,
        property: property
    )
    while try machine.next() != nil {}
    return machine.stats
}
