import Exhaust
import Testing

// MARK: - Tests

@Suite("ALU state machine tests")
struct ALUTests {
    @Test("SCA argument coverage finds narrow ALU multiply bug")
    func scaFindsNarrowMultiplyBug() throws {
        // The multiply bug only fires when value × factor ≥ 13.
        // Triggering paths (shortest): store(4) + add(3) + multiply(2) → 14, store(3) + add(2) + multiply(3) → 15, store(1) + subtract(3) + multiply(2) → 28 (via 0xF wrap to 14).
        // Random at 100 iterations hits one of these ~20% of the time. SCA with 16 domain values at t=2 produces ~256+ rows covering all pairwise (command+arg) interactions, reliably surfacing the failure.
        let result = try #require(
            #exhaust(
                ALUSpec.self,
                commandLimit: 8,
                .argumentAwareCoverage,
                .suppressIssueReporting,
                .useBonsaiReducer
            )
        )

        #expect(result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        })
    }
}

// MARK: - Contract

@Contract
struct ALUSpec {
    @Model var expected: Int = 0
    @SUT var alu = FourBitALU()

    @Invariant
    func registersMatch() -> Bool {
        alu.value == expected
    }

    // store: 5 arg values  → 5 domain slots
    @Command(weight: 2, #gen(.int(in: 0 ... 4)))
    mutating func store(value: Int) throws {
        expected = value
        alu.store(value)
    }

    // add: 4 arg values    → 4 domain slots
    @Command(weight: 2, #gen(.int(in: 1 ... 4)))
    mutating func add(operand: Int) throws {
        expected = (expected + operand) & 0xF
        alu.add(operand)
    }

    // multiply: 2 arg values → 2 domain slots  (the buggy operation)
    @Command(weight: 1, #gen(.int(in: 2 ... 3)))
    mutating func multiply(factor: Int) throws {
        expected = (expected * factor) & 0xF
        alu.multiply(factor)
    }

    // subtract: 3 arg values → 3 domain slots
    @Command(weight: 1, #gen(.int(in: 1 ... 3)))
    mutating func subtract(amount: Int) throws {
        expected = (expected - amount) & 0xF
        alu.subtract(amount)
    }

    // increment: param-free  → 1 domain slot
    @Command(weight: 1)
    mutating func increment() throws {
        expected = (expected + 1) & 0xF
        alu.increment()
    }

    // clear: param-free → 1 domain slot
    // total: 16 domain values per position
    @Command(weight: 1)
    mutating func clear() throws {
        expected = 0
        alu.clear()
    }
}

// MARK: - Types

/// A 4-bit hardware register simulator. All operations use 4-bit modular arithmetic (`& 0xF`, that is, mod 16) — except `multiply`, which has a deliberate bug: it reduces mod 13 instead of mod 16. The two moduli agree for products 0–12, so the bug only manifests when `value × factor ≥ 13`. Reaching that threshold requires a specific prior sequence of `store` + `add` (or `subtract` wrapping high) with the right argument values, followed by a `multiply` with the right factor — a narrow 3-command interaction window.
///
/// With 6 commands (4 parameterized) and 16 domain values per sequence position, random testing at 100 iterations finds the failure roughly 20% of the time. SCA with argument-aware domains covers it deterministically via pairwise coverage of command+argument combinations across positions.
struct FourBitALU {
    private(set) var value: Int = 0

    mutating func store(_ v: Int) {
        value = v
    }

    mutating func add(_ v: Int) {
        value = (value + v) & 0xF
    }

    mutating func multiply(_ v: Int) {
        value = (value * v) % 13
    }

    mutating func subtract(_ v: Int) {
        value = (value - v) & 0xF
    }

    mutating func increment() {
        value = (value + 1) & 0xF
    }

    mutating func clear() {
        value = 0
    }
}
