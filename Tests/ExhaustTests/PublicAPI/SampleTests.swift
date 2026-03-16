import Testing
@testable import Exhaust

// SPI import removed — no internal ExhaustCore types needed

@Suite("#example runtime tests")
struct ExampleTests {
    @Test("Single example produces a value in the generator's range")
    func singleValueInRange() {
        let value = #example(.int(in: 1 ... 100))
        #expect((1 ... 100).contains(value))
    }

    @Test("Array example produces the requested count")
    func arrayCount() {
        let values = #example(.int(in: 1 ... 100), count: 20)
        print()
        #expect(values.count == 20)
        for value in values {
            #expect((1 ... 100).contains(value))
        }
    }

    @Test("Same seed produces identical single values")
    func deterministicReplaySingle() {
        let a = #example(.int(in: 0 ... 1_000_000), seed: 99)
        let b = #example(.int(in: 0 ... 1_000_000), seed: 99)
        #expect(a == b)
    }

    @Test("Same seed produces identical arrays")
    func deterministicReplayArray() {
        let a = #example(.int(in: 0 ... 1_000_000), count: 10, seed: 99)
        let b = #example(.int(in: 0 ... 1_000_000), count: 10, seed: 99)
        #expect(a == b)
    }

    @Test("Different seeds produce different values")
    func differentSeeds() {
        let a = #example(.int(in: 0 ... 1_000_000), seed: 1)
        let b = #example(.int(in: 0 ... 1_000_000), seed: 2)
        #expect(a != b)
    }
}
