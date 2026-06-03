import Testing
@testable import Exhaust

// SPI import removed — no internal ExhaustCore types needed

@Suite("#example runtime tests")
struct ExampleTests {
    @Test("Single example produces a value in the generator's range")
    func singleValueInRange() throws {
        let value = try #example(.int(in: 1 ... 100))
        #expect((1 ... 100).contains(value))
    }

    @Test("Array example produces the requested count")
    func arrayCount() throws {
        let values = try #example(.int(in: 1 ... 100), count: 20)
        print()
        #expect(values.count == 20)
        for value in values {
            #expect((1 ... 100).contains(value))
        }
    }

    @Test("Same seed produces identical single values")
    func deterministicReplaySingle() throws {
        let a = try #example(.int(in: 0 ... 1_000_000), seed: 99)
        let b = try #example(.int(in: 0 ... 1_000_000), seed: 99)
        #expect(a == b)
    }

    @Test("Same seed produces identical arrays")
    func deterministicReplayArray() throws {
        let a = try #example(.int(in: 0 ... 1_000_000), count: 10, seed: 99)
        let b = try #example(.int(in: 0 ... 1_000_000), count: 10, seed: 99)
        #expect(a == b)
    }

    @Test("Different seeds produce different values")
    func differentSeeds() throws {
        let a = try #example(.int(in: 0 ... 1_000_000), seed: 1)
        let b = try #example(.int(in: 0 ... 1_000_000), seed: 2)
        #expect(a != b)
    }
}
