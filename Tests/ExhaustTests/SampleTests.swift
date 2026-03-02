import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("#sample runtime tests")
struct SampleTests {
    @Test("Single sample produces a value in the generator's range")
    func singleValueInRange() {
        let value = #sample(Gen.choose(in: 1 ... 100))
        #expect((1 ... 100).contains(value))
    }

    @Test("Array sample produces the requested count")
    func arrayCount() {
        let values = #sample(Gen.choose(in: 1 ... 100), count: 20)
        print()
        #expect(values.count == 20)
        for value in values {
            #expect((1 ... 100).contains(value))
        }
    }

    @Test("Same seed produces identical single values")
    func deterministicReplaySingle() {
        let a = #sample(Gen.choose(in: 0 ... 1_000_000), seed: 99)
        let b = #sample(Gen.choose(in: 0 ... 1_000_000), seed: 99)
        #expect(a == b)
    }

    @Test("Same seed produces identical arrays")
    func deterministicReplayArray() {
        let a = #sample(Gen.choose(in: 0 ... 1_000_000), count: 10, seed: 99)
        let b = #sample(Gen.choose(in: 0 ... 1_000_000), count: 10, seed: 99)
        #expect(a == b)
    }

    @Test("Different seeds produce different values")
    func differentSeeds() {
        let a = #sample(Gen.choose(in: 0 ... 1_000_000), seed: 1)
        let b = #sample(Gen.choose(in: 0 ... 1_000_000), seed: 2)
        #expect(a != b)
    }
}
