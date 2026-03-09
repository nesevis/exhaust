import Testing
import Exhaust
import ExhaustCore

// MARK: - Test SUT: Simple counter with a known bug

/// A counter that wraps to zero after reaching a threshold. The bug: it wraps at 3 instead of the stated capacity of 5.
struct BuggyCounter {
    private(set) var value: Int = 0
    let capacity: Int

    mutating func increment() {
        value = (value + 1) % capacity
    }

    mutating func reset() {
        value = 0
    }
}

// MARK: - State Machine Spec

@StateMachine
struct BuggyCounterSpec {
    @Model var expectedValue: Int = 0
    @SUT var counter = BuggyCounter(capacity: 3)

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expectedValue
    }

    @Command(weight: 3)
    mutating func increment() throws {
        // Model uses capacity 5, SUT uses capacity 3 — diverges after 3 increments
        expectedValue = (expectedValue + 1) % 5
        counter.increment()
    }

    @Command(weight: 1)
    mutating func reset() throws {
        expectedValue = 0
        counter.reset()
    }
}

// MARK: - Passing spec: simple stack

@StateMachine
struct StackSpec {
    @Model var expected: [Int] = []
    @SUT var stack: [Int] = []

    @Invariant
    func contentsMatch() -> Bool {
        stack == expected
    }

    @Command(weight: 3, Gen.int(in: 0...9))
    mutating func push(value: Int) throws {
        expected.append(value)
        stack.append(value)
    }

    @Command(weight: 2)
    mutating func pop() throws {
        guard !expected.isEmpty else { throw skip() }
        let modelValue = expected.removeLast()
        let sutValue = stack.removeLast()
        try check(modelValue == sutValue, "pop values should match")
    }

    @Command(weight: 1)
    mutating func count() throws {
        try check(expected.count == stack.count, "counts should match")
    }
}

// MARK: - SCA torture test: 4-bit ALU with narrow multiply bug

/// A 4-bit hardware register simulator.
///
/// All operations use 4-bit modular arithmetic (`& 0xF`, i.e. mod 16) —
/// except `multiply`, which has a deliberate bug: it reduces mod 13 instead
/// of mod 16. The two moduli agree for products 0–12, so the bug only
/// manifests when `value × factor ≥ 13`. Reaching that threshold requires a
/// specific prior sequence of `store` + `add` (or `subtract` wrapping high)
/// with the right argument values, followed by a `multiply` with the right
/// factor — a narrow 3-command interaction window.
///
/// With 6 commands (4 parameterized) and 16 domain values per sequence
/// position, random testing at 100 iterations finds the failure roughly 20%
/// of the time. SCA with argument-aware domains covers it deterministically
/// via pairwise coverage of command+argument combinations across positions.
struct FourBitALU {
    private(set) var value: Int = 0

    mutating func store(_ v: Int) { value = v }
    mutating func add(_ v: Int) { value = (value + v) & 0xF }
    mutating func multiply(_ v: Int) { value = (value * v) % 13 }
    mutating func subtract(_ v: Int) { value = (value - v) & 0xF }
    mutating func increment() { value = (value + 1) & 0xF }
    mutating func clear() { value = 0 }
}

@StateMachine
struct ALUSpec {
    @Model var expected: Int = 0
    @SUT var alu = FourBitALU()

    @Invariant
    func registersMatch() -> Bool {
        alu.value == expected
    }

    // store: 5 arg values  → 5 domain slots
    @Command(weight: 2, Gen.int(in: 0...4))
    mutating func store(value: Int) throws {
        expected = value
        alu.store(value)
    }

    // add: 4 arg values    → 4 domain slots
    @Command(weight: 2, Gen.int(in: 1...4))
    mutating func add(operand: Int) throws {
        expected = (expected + operand) & 0xF
        alu.add(operand)
    }

    // multiply: 2 arg values → 2 domain slots  (the buggy operation)
    @Command(weight: 1, Gen.int(in: 2...3))
    mutating func multiply(factor: Int) throws {
        expected = (expected * factor) & 0xF
        alu.multiply(factor)
    }

    // subtract: 3 arg values → 3 domain slots
    @Command(weight: 1, Gen.int(in: 1...3))
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

    // clear: param-free      → 1 domain slot
    //                    total: 16 domain values per position
    @Command(weight: 1)
    mutating func clear() throws {
        expected = 0
        alu.clear()
    }
}

// MARK: - Tests

@Suite("State machine integration tests")
struct StateMachineIntegrationTests {
    @Test("Detects model/SUT divergence in buggy counter")
    func detectsBuggyCounter() throws {
        let result = try #require(
            #stateMachine(BuggyCounterSpec.self, .sequenceLength(3...10), .suppressIssueReporting)
        )
        print()
        // The trace should end with a failing step
        #expect(result.trace.last.map { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        } == true)

        // The SUT should be a BuggyCounter with capacity 3
        #expect(result.sut.capacity == 3)
    }

    @Test("Passing spec produces no counterexample")
    func passingStack() {
        let result = #stateMachine(StackSpec.self, .sequenceLength(5...15), .maxIterations(50), .suppressIssueReporting)
        #expect(result == nil, "Stack spec should pass — model and SUT are identical")
    }

    @Test("SCA argument coverage finds narrow ALU multiply bug")
    func scaFindsNarrowMultiplyBug() throws {
        // The multiply bug only fires when value × factor ≥ 13.
        // Triggering paths (shortest): store(4) + add(3) + multiply(2)  → 14
        //                              store(3) + add(2) + multiply(3)  → 15
        //                              store(1) + subtract(3) + multiply(2) → 28 (via 0xF wrap to 14)
        // Random at 100 iterations hits one of these ~20% of the time.
        // SCA with 16 domain values at t=2 produces ~256+ rows covering all
        // pairwise (command+arg) interactions, reliably surfacing the failure.
        let result = try #require(
            #stateMachine(
                ALUSpec.self,
                .sequenceLength(5...8),
                .maxIterations(0),
                .suppressIssueReporting
            )
        )

        print("Commands: \(result.commands.count)")
        for step in result.trace {
            print("  \(step)")
        }
        print("ALU value: \(result.sut.value), expected: \(result.commands)")

        #expect(result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        })
    }

    @Test("Trace steps have correct structure")
    func traceSteps() throws {
        let result = try #require(
            #stateMachine(BuggyCounterSpec.self, .sequenceLength(3...10), .suppressIssueReporting)
        )

        // Every step should have a 1-based index
        for (offset, step) in result.trace.enumerated() {
            #expect(step.index == offset + 1)
        }

        // At least the last step should not be .ok (it's the failing step)
        if let lastStep = result.trace.last {
            if case .ok = lastStep.outcome {
                Issue.record("Last trace step should be a failure, not .ok")
            }
        }

        // Trace descriptions should be non-empty
        for step in result.trace {
            #expect(!step.description.isEmpty)
        }
    }
}
