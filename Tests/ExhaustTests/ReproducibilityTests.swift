//
//  ReproducibilityTests.swift
//  Exhaust
//

import Testing
@testable import Exhaust
import ExhaustCore

@Suite("Per-run seeding reproducibility")
struct ReproducibilityTests {
    // MARK: - ValueAndChoiceTreeInterpreter

    @Test("Same seed produces identical value sequences")
    func seedDeterminism() {
        let gen = #gen(.int())
        var iter1 = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)
        let values1 = Array(collecting: &iter1).map(\.value)
        var iter2 = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)
        let values2 = Array(collecting: &iter2).map(\.value)
        #expect(values1 == values2)
    }

    @Test("Different maxRuns with same seed share a common prefix")
    func maxRunsIndependence() {
        let gen = #gen(.int())
        var shortIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 50)
        let short = shortIter.prefix(30).map(\.value)
        var longIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 200)
        let long = longIter.prefix(30).map(\.value)
        #expect(short == long)
    }

    // MARK: - ValueInterpreter

    @Test("ValueInterpreter: same seed produces identical value sequences")
    func valueInterpreterSeedDeterminism() {
        let gen = #gen(.int())
        var valIter1 = ValueInterpreter(gen, seed: 42, maxRuns: 20)
        let values1 = Array(collecting: &valIter1)
        var valIter2 = ValueInterpreter(gen, seed: 42, maxRuns: 20)
        let values2 = Array(collecting: &valIter2)
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
