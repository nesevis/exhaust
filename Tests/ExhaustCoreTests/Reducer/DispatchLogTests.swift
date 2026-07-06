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
    @Test("Records one entry per pass, consistent with aggregate counters")
    func recordsConsistentDispatchLog() throws {
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

        var machine = ReductionMachine(
            gen: gen,
            initialTree: tree,
            initialOutput: value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            collectStats: true,
            property: property
        )
        machine.collectDiagnostics = true
        while try machine.next() != nil {}

        let log = machine.stats.dispatchLog
        #expect(log.isEmpty == false)

        // Pass indices strictly increase: the log preserves dispatch order.
        let passIndices = log.map(\.passIndex)
        #expect(passIndices == passIndices.sorted())
        #expect(Set(passIndices).count == passIndices.count)

        // Value search must have accepted at least once (both coordinates reduce to 10). On this value-only workload no accepting pass changes length or moves away from targets, and at least one strictly improves distance. Order-canonicalizing accepts (numeric reorder, sibling swap) are distance-neutral because permutation preserves the distance sum.
        let acceptingRecords = log.filter { $0.acceptCount > 0 }
        #expect(acceptingRecords.isEmpty == false)
        for record in acceptingRecords {
            #expect(record.sequenceLengthDelta == 0)
            #expect(record.targetDistanceDelta >= 0)
        }
        #expect(acceptingRecords.contains { $0.targetDistanceDelta > 0 })

        // The log is a refinement of the aggregate counters: per-encoder sums must match exactly.
        var probesFromLog: [EncoderName: Int] = [:]
        var acceptsFromLog: [EncoderName: Int] = [:]
        for record in log {
            probesFromLog[record.encoderName, default: 0] += record.probeCount
            acceptsFromLog[record.encoderName, default: 0] += record.acceptCount
        }
        for (encoder, probes) in machine.stats.encoderProbes where encoder != .convergenceConfirmation {
            #expect(probesFromLog[encoder, default: 0] == probes, "probe counts must match for \(encoder)")
        }
        for (encoder, accepts) in machine.stats.encoderProbesAccepted where encoder != .convergenceConfirmation {
            #expect(acceptsFromLog[encoder, default: 0] == accepts, "accept counts must match for \(encoder)")
        }
    }

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

        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            property: property
        )

        #expect(result.stats.dispatchLog.isEmpty)
    }
}
