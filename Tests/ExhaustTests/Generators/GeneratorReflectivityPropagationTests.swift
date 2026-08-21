//
//  GeneratorReflectivityPropagationTests.swift
//  ExhaustTests
//

import Exhaust
import Testing

@Suite("Reflectivity Propagation Through Public Factories")
struct GeneratorReflectivityPropagationTests {
    private var reflectiveElement: ReflectiveGenerator<Int> {
        #gen(.int(in: 0 ... 100))
    }

    private var brokenElement: ReflectiveGenerator<Int> {
        #gen(.int(in: 0 ... 100)).map { $0 * 2 }
    }

    @Test("Array factories propagate the element's reflectivity")
    func arrayPropagatesElementFlag() {
        #expect(reflectiveElement.array().isReflective)
        #expect(reflectiveElement.array(length: 1 ... 3).isReflective)
        #expect(brokenElement.array().isReflective == false)
        #expect(brokenElement.array(length: 1 ... 3).isReflective == false)
        #expect(brokenElement.array(length: 2).isReflective == false)
    }

    @Test("eachOf is reflective only when every input is")
    func eachOfPropagatesInputFlags() {
        #expect(ReflectiveGenerator<[Int]>.eachOf([reflectiveElement, reflectiveElement]).isReflective)
        #expect(ReflectiveGenerator<[Int]>.eachOf([reflectiveElement, brokenElement]).isReflective == false)
    }

    @Test("Set and dictionary construction are never reflective: they discard draw order and collapse duplicates")
    func setAndDictionaryAreNeverReflective() {
        #expect(reflectiveElement.set().isReflective == false)
        #expect(ReflectiveGenerator<[Int: Int]>.dictionary(reflectiveElement, reflectiveElement).isReflective == false)
    }

    @Test("Range factories propagate the bound generator's reflectivity")
    func rangePropagatesBoundFlag() {
        #expect(ReflectiveGenerator<ClosedRange<Int>>.closedRange(reflectiveElement).isReflective)
        #expect(ReflectiveGenerator<ClosedRange<Int>>.closedRange(brokenElement).isReflective == false)
    }

    @Test("Filter is transparent to reflectivity")
    func filterPropagatesInnerFlag() {
        #expect(reflectiveElement.filter { $0.isMultiple(of: 2) }.isReflective)
        #expect(brokenElement.filter { $0.isMultiple(of: 2) }.isReflective == false)
    }

    @Test("Initializer-shaped #gen stays reflective over reflective inputs and propagates a broken one")
    func macroZipPropagatesInputFlags() {
        let intact = #gen(.int(in: 0 ... 100), .int(in: 0 ... 100)) { first, second in
            Pair(first: first, second: second)
        }
        #expect(intact.isReflective)

        let broken = brokenElement
        let tainted = #gen(broken, .int(in: 0 ... 100)) { first, second in
            Pair(first: first, second: second)
        }
        #expect(tainted.isReflective == false)
    }

    @Test("Synthesized generators are forward-only and claim no reflectivity")
    func synthesizedGeneratorsAreNotReflective() throws {
        let gen = try #gen(Pair.self, from: #"{"first": 1, "second": 2}"#)
        #expect(gen.isReflective == false)
    }
}

// MARK: - Supporting Types

private struct Pair: Codable, Equatable {
    let first: Int
    let second: Int
}
