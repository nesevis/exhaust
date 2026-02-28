//
//  InterpreterRNGParityTests.swift
//  Exhaust
//
//  Created by Claude Code on 07/02/2026.
//

import Foundation
import Testing
@testable import Exhaust
@_spi(ExhaustInternal) @testable import ExhaustCore

@Suite("Interpreter RNG Parity")
struct InterpreterRNGParityTests {
    // MARK: - Basic Types

    @Test("Int generation parity")
    func intGenerationParity() {
        let gen = Int.arbitrary
        let seed: UInt64 = 42

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("UInt64 generation parity")
    func uInt64GenerationParity() {
        let gen = UInt64.arbitrary
        let seed: UInt64 = 12345

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Bool generation parity")
    func boolGenerationParity() {
        let gen = Bool.arbitrary
        let seed: UInt64 = 999

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 20)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 20)

        for iteration in 0 ..< 20 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Float generation parity")
    func floatGenerationParity() {
        let gen = Float.arbitrary
        let seed: UInt64 = 7777

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue.bitPattern == vactValue.bitPattern, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Double generation parity")
    func doubleGenerationParity() {
        let gen = Double.arbitrary
        let seed: UInt64 = 8888

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue.bitPattern == vactValue.bitPattern, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    // MARK: - Pick Operations

    @Test("Simple pick parity with equal weights")
    func simplePickParity() {
        let gen = Gen.pick(choices: [
            (1, Gen.just(100)),
            (1, Gen.just(200)),
        ])
        let seed: UInt64 = 42

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 20)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 20)

        for iteration in 0 ..< 20 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Pick parity with weighted choices")
    func weightedPickParity() {
        let gen = Gen.pick(choices: [
            (3, Gen.just("A")),
            (1, Gen.just("B")),
            (2, Gen.just("C")),
        ])
        let seed: UInt64 = 555

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 30)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 30)

        for iteration in 0 ..< 30 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Pick parity with generated values")
    func pickWithGeneratedValuesParity() {
        let gen = Gen.pick(choices: [
            (1, UInt64.arbitrary),
            (1, UInt64.arbitrary),
        ])
        let seed: UInt64 = 4

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 15)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 15)

        for iteration in 0 ..< 15 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Nested pick parity")
    func nestedPickParity() {
        let innerPick = Gen.pick(choices: [
            (1, Gen.just(1)),
            (1, Gen.just(2)),
        ])
        let outerPick = Gen.pick(choices: [
            (1, innerPick),
            (1, Gen.just(10)),
        ])
        let seed: UInt64 = 333

        var vi = ValueInterpreter(outerPick, seed: seed, maxRuns: 20)
        var vact = ValueAndChoiceTreeInterpreter(outerPick, materializePicks: true, seed: seed, maxRuns: 20)

        for iteration in 0 ..< 20 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    // MARK: - Collections

    @Test("Array generation parity")
    func arrayGenerationParity() {
        let gen = Gen.arrayOf(UInt64.arbitrary, exactly: 5)
        let seed: UInt64 = 1111

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 5)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed, maxRuns: 5)

        for iteration in 0 ..< 5 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Variable length array parity")
    func variableLengthArrayParity() {
        let gen = Int.arbitrary.proliferate(with: 2 ... 5)
        let seed: UInt64 = 2222

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 5)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 5)

        for iteration in 0 ..< 5 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): arrays have different values")
        }
    }

    // MARK: - Zip Operations

    @Test("Zip two generators parity")
    func zipTwoParity() {
        let gen = Gen.zip(UInt64.arbitrary, Int.arbitrary)
        let seed: UInt64 = 3333

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue.0 == vactValue.0 && viValue.1 == vactValue.1, "Iteration \(iteration): tuples don't match")
        }
    }

    @Test("Zip three generators parity")
    func zipThreeParity() {
        let gen = Gen.zip(UInt64.arbitrary, Int.arbitrary, Bool.arbitrary)
        let seed: UInt64 = 4444

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue.0 == vactValue.0 && viValue.1 == vactValue.1 && viValue.2 == vactValue.2, "Iteration \(iteration): tuples don't match")
        }
    }

    // MARK: - Map and FlatMap

    @Test("Mapped generator parity")
    func mappedGeneratorParity() {
        let gen = UInt64.arbitrary.map { $0 % 100 }
        let seed: UInt64 = 5555

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("FlatMapped generator parity")
    func flatMappedGeneratorParity() {
        let gen = Gen.choose(in: 1 ... 10).bind { size in
            Gen.arrayOf(UInt64.arbitrary, exactly: UInt64(size))
        }
        let seed: UInt64 = 6666

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 5)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 5)

        for iteration in 0 ..< 5 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): arrays have different values")
        }
    }

    // MARK: - Complex Compositions

    @Test("Complex composition parity")
    func complexCompositionParity() {
        let gen = Gen.zip(
            Gen.pick(choices: [
                (2, UInt64.arbitrary),
                (1, Gen.just(999)),
            ]),
            Gen.arrayOf(Bool.arbitrary, exactly: 3),
            Gen.choose(in: 0 ... 100),
        )
        let seed: UInt64 = 9999

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 10)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 10)

        for iteration in 0 ..< 10 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue.0 == vactValue.0, "Iteration \(iteration): first component mismatch")
            #expect(viValue.1 == vactValue.1, "Iteration \(iteration): second component mismatch")
            #expect(viValue.2 == vactValue.2, "Iteration \(iteration): third component mismatch")
        }
    }

    @Test("Deeply nested composition parity")
    func deeplyNestedCompositionParity() {
        let innerGen = Gen.zip(UInt64.arbitrary, Bool.arbitrary)
        let middleGen = Gen.pick(choices: [
            (1, innerGen.map { ($0.0, $0.1, 1) }),
            (1, innerGen.map { ($0.0, $0.1, 2) }),
        ])
        let outerGen = Gen.arrayOf(middleGen, exactly: 3)
        let seed: UInt64 = 11111

        var vi = ValueInterpreter(outerGen, seed: seed, maxRuns: 5)
        var vact = ValueAndChoiceTreeInterpreter(outerGen, materializePicks: true, seed: seed, maxRuns: 5)

        for iteration in 0 ..< 5 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!

            #expect(viValue.count == vactValue.count, "Iteration \(iteration): array lengths differ")
            for (idx, (viElem, vactElem)) in zip(viValue, vactValue).enumerated() {
                #expect(viElem.0 == vactElem.0 && viElem.1 == vactElem.1 && viElem.2 == vactElem.2,
                        "Iteration \(iteration), element \(idx): tuples don't match")
            }
        }
    }

    // MARK: - Edge Cases

    @Test("Single element pick parity")
    func singleElementPickParity() {
        let gen = Gen.pick(choices: [
            (1, Gen.just(42)),
        ])
        let seed: UInt64 = 12345

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 5)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 5)

        for iteration in 0 ..< 5 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue == vactValue, "Iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
        }
    }

    @Test("Empty array generation parity")
    func emptyArrayParity() {
        let gen = Gen.arrayOf(UInt64.arbitrary, exactly: 0)
        let seed: UInt64 = 54321

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 5)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 5)

        for iteration in 0 ..< 5 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue.isEmpty && vactValue.isEmpty, "Iteration \(iteration): both should be empty arrays")
        }
    }

    @Test("Many iterations parity stress test")
    func manyIterationsParity() {
        let gen = Gen.zip(UInt64.arbitrary, Bool.arbitrary, Int.arbitrary)
        let seed: UInt64 = 99999

        var vi = ValueInterpreter(gen, seed: seed, maxRuns: 100)
        var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 100)

        for iteration in 0 ..< 100 {
            let viValue = vi.next()!
            let (vactValue, _) = vact.next()!
            #expect(viValue.0 == vactValue.0 && viValue.1 == vactValue.1 && viValue.2 == vactValue.2,
                    "Iteration \(iteration): tuples don't match")
        }
    }

    @Test("Multiple seeds produce different but consistent results")
    func multipleSeedsParity() {
        let gen = String.arbitrary
        let seeds: [UInt64] = [1, 42, 100, 999, 12345]

        for seed in seeds {
            var vi = ValueInterpreter(gen, seed: seed, maxRuns: 5)
            var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: 5)

            for iteration in 0 ..< 5 {
                let viValue = vi.next()!
                let (vactValue, _) = vact.next()!
                #expect(viValue == vactValue, "Seed \(seed), iteration \(iteration): ValueInterpreter=\(viValue), ValueAndChoiceTreeInterpreter=\(vactValue)")
            }
        }
    }
}
