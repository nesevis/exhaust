//
//  InterpreterRNGParityTests.swift
//  Exhaust
//
//  Created by Claude Code on 07/02/2026.
//

import Foundation
import Testing
@testable import Exhaust
import ExhaustCore

@Suite("Interpreter RNG Parity")
struct InterpreterRNGParityTests {
    // MARK: - Basic Types

    @Test("Int generation parity")
    func intGenerationParity() {
        let gen = #gen(.int())
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
        let gen = #gen(.uint64())
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
        let gen = #gen(.bool())
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
        let gen = #gen(.float())
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
        let gen = #gen(.double())
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
        let gen = #gen(.oneOf(weighted:
            (1, .just(100)),
            (1, .just(200))))
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
        let gen = #gen(.oneOf(weighted:
            (3, .just("A")),
            (1, .just("B")),
            (2, .just("C"))))
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
        let gen = #gen(.oneOf(weighted:
            (1, .uint64()),
            (1, .uint64())))
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
        let innerPick = #gen(.oneOf(weighted:
            (1, .just(1)),
            (1, .just(2))))
        let outerPick = #gen(.oneOf(weighted:
            (1, innerPick),
            (1, .just(10))))
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
        let gen = #gen(.uint64()).array(length: 5)
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
        let gen = #gen(.int()).array(length: 2 ... 5)
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
        let gen = #gen(.uint64(), .int())
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
        let gen = #gen(.uint64(), .int(), .bool())
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
        let gen = #gen(.uint64()).map { $0 % 100 }
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
        let gen = #gen(.int(in: 1 ... 10)).bind { size in
            #gen(.uint64()).array(length: UInt64(size))
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
        let gen = #gen(
            #gen(.oneOf(weighted:
                (2, .uint64()),
                (1, .just(999)))),
            #gen(.bool()).array(length: 3),
            .int(in: 0 ... 100),
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
        let innerGen = #gen(.uint64(), .bool())
        let middleGen = #gen(.oneOf(weighted:
            (1, innerGen.map { ($0.0, $0.1, 1) }),
            (1, innerGen.map { ($0.0, $0.1, 2) })))
        let outerGen = middleGen.array(length: 3)
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
        let gen = #gen(.oneOf(weighted:
            (1, .just(42))))
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
        let gen = #gen(.uint64()).array(length: 0)
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
        let gen = #gen(.uint64(), .bool(), .int())
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
        let gen = #gen(.string())
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
