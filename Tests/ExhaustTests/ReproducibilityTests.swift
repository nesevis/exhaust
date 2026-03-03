//
//  ReproducibilityTests.swift
//  Exhaust
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Per-run seeding reproducibility")
struct ReproducibilityTests {
    // MARK: - ValueAndChoiceTreeInterpreter

    @Test("Same seed produces identical value sequences")
    func seedDeterminism() {
        let gen = #gen(.int())
        let values1 = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)
            .map(\.value)
        let values2 = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)
            .map(\.value)
        #expect(Array(values1) == Array(values2))
    }

    @Test("Different maxRuns with same seed share a common prefix")
    func maxRunsIndependence() {
        let gen = #gen(.int())
        let short = Array(
            ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 50)
                .prefix(30)
                .map(\.value),
        )
        let long = Array(
            ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 200)
                .prefix(30)
                .map(\.value),
        )
        #expect(short == long)
    }

    // MARK: - ValueInterpreter

    @Test("ValueInterpreter: same seed produces identical value sequences")
    func valueInterpreterSeedDeterminism() {
        let gen = #gen(.int())
        let values1 = Array(ValueInterpreter(gen, seed: 42, maxRuns: 20))
        let values2 = Array(ValueInterpreter(gen, seed: 42, maxRuns: 20))
        #expect(values1 == values2)
    }

    // MARK: - GenerationContext helpers

    @Test("scaledSize cycles 1...100 independently of maxRuns")
    func scaledSizeCycling() {
        // All 100 sizes appear in each cycle
        let fullCycle = (0 as UInt64 ..< 100).map { GenerationContext.scaledSize(forRun: $0) }
        #expect(Set(fullCycle) == Set(1 ... 100))

        // Range and periodicity hold for arbitrary run indices
        #exhaust(#gen(.uint64(in: 0 ... 10000))) { n in
            let size = GenerationContext.scaledSize(forRun: n)
            let cycled = GenerationContext.scaledSize(forRun: n + 100)
            return size >= 1 && size <= 100 && size == cycled
        }
    }

    @Test("runSeed produces distinct seeds for 1000 consecutive runs")
    func runSeedDistinctness() {
        let seeds = Set((0 as UInt64 ..< 1000).map { GenerationContext.runSeed(base: 42, runIndex: $0) })
        #expect(seeds.count == 1000)
    }
}
