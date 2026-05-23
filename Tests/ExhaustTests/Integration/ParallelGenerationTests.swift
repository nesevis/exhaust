import Testing
@testable import Exhaust

@Suite("Parallel generation")
struct ParallelGenerationTests {
    @Test
    func `Offset batches produce identical values to sequential generation`() throws {
        let gen = #gen(.int(in: 0 ... 10000)).gen
        let seed: UInt64 = 42
        let totalRuns: UInt64 = 200

        var sequentialValues: [Int] = []
        var sequential = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: totalRuns)
        while let value = try sequential.nextValueOnly() {
            sequentialValues.append(value)
        }

        var batch0Values: [Int] = []
        var batch0 = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 100, initialRunIndex: 0)
        while let value = try batch0.nextValueOnly() {
            batch0Values.append(value)
        }

        var batch1Values: [Int] = []
        var batch1 = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 200, initialRunIndex: 100)
        while let value = try batch1.nextValueOnly() {
            batch1Values.append(value)
        }

        #expect(sequentialValues.count == 200)
        #expect(batch0Values.count == 100)
        #expect(batch1Values.count == 100)
        #expect(sequentialValues == batch0Values + batch1Values)
    }

    @Test
    func `Parallel passes when no counterexample exists`() {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.thorough),
            .parallelize,
            .randomOnly,
            .onReport { capturedReport = $0 }
        ) { $0 >= 0 }

        #expect(result == nil)
        #expect(capturedReport?.randomSamplingInvocations == 600)
    }

    @Test
    func `Parallel finds counterexample`() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 10000)),
            .budget(.thorough),
            .parallelize,
            .randomOnly,
            .suppress(.issueReporting)
        ) { $0 < 5 }

        #expect(result != nil)
    }

    @Test
    func `Early cancellation stops other batches`() throws {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 10000)),
            .budget(.extensive),
            .parallelize,
            .randomOnly,
            .suppress(.issueReporting),
            .onReport { capturedReport = $0 }
        ) { $0 < 5 }

        #expect(result != nil)
        let report = try #require(capturedReport)
        #expect(report.randomSamplingInvocations < 2000, "Should stop early, not run the full budget")
    }

    @Test
    func `Filtered generator works across parallel lanes`() throws {
        let gen = #gen(.int(in: 0 ... 100)).filter { $0 % 2 == 0 }
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            gen,
            .budget(.standard),
            .parallelize,
            .randomOnly,
            .onReport { capturedReport = $0 }
        ) { $0 >= 0 }

        #expect(result == nil)
        let report = try #require(capturedReport)
        #expect(report.randomSamplingInvocations == 200)
    }

    @Test
    func `Replay with parallelize runs sequentially`() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 10000)),
            .replay(.numeric(42)),
            .parallelize,
            .suppress(.issueReporting)
        ) { $0 < 400 }

        #expect(result != nil)
    }

    @Test
    func `Budget under 200 falls through to sequential`() {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.quick),
            .parallelize,
            .randomOnly,
            .onReport { capturedReport = $0 }
        ) { $0 >= 0 }

        #expect(result == nil)
        #expect(capturedReport?.randomSamplingInvocations == 100)
    }

    @Test
    func `Stats lines carry lane field in parallel mode`() throws {
        var capturedReport: ExhaustReport?
        #exhaust(
            #gen(.int(in: 0 ... 100)),
            .budget(.standard),
            .parallelize,
            .randomOnly,
            .collectOpenPBTStats,
            .onReport { capturedReport = $0 }
        ) { $0 >= 0 }

        let report = try #require(capturedReport)
        let lines = report.openPBTStatsLines
        #expect(lines.isEmpty == false)
        #expect(lines.allSatisfy { $0.lane != nil })
        let lanes = Set(lines.compactMap(\.lane))
        #expect(lanes.count == 2, "Standard budget should use 2 lanes")
    }
}
