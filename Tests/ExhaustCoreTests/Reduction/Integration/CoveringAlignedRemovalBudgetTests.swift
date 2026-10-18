import Testing
@testable import ExhaustCore

@Suite("Covering aligned removal row budget")
struct CoveringAlignedRemovalBudgetTests {
    @Test("Aligned removal over sibling arrays too large to track finishes before the deadline when no deletion is accepted")
    func graphReducerFinishesBeforeDeadline() throws {
        let fixture = try UntrackedSiblingArrays()
        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: fixture.generator,
            tree: fixture.tree,
            output: fixture.value,
            config: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: UntrackedSiblingArrays.deadlineNanoseconds,
                enabledEncoders: [.deletion]
            ),
            property: UntrackedSiblingArrays.property
        )

        #expect(result.stats.reductionWasCapped == false)
    }

    @Test("Aligned removal over sibling arrays too large to track finishes before the deadline when no deletion is accepted")
    func reductionFinishesBeforeDeadline() throws {
        let fixture = try UntrackedSiblingArrays()
        let result = ReductionSession.reduce(
            generator: fixture.generator,
            tree: fixture.tree,
            output: fixture.value,
            configuration: ReductionSession.Configuration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: UntrackedSiblingArrays.deadlineNanoseconds,
                enabledEncoders: [.deletion]
            ),
            collectStats: true,
            property: UntrackedSiblingArrays.property
        )

        #expect(result.stats.reductionWasCapped == false)
    }
}

// MARK: - Fixture

/// Two zipped arrays of 70 elements: each sibling's domain is 71 values, so the pair space exceeds the covering generator's tracking threshold and its row stream never ends. The property fails only at full length, so no aligned deletion is ever accepted.
private struct UntrackedSiblingArrays {
    static let elementCount = 70
    static let deadlineNanoseconds: UInt64 = 3_000_000_000

    let generator: Generator<([UInt64], [UInt64])>
    let value: ([UInt64], [UInt64])
    let tree: ChoiceTree

    init() throws {
        let array = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 9), within: 0 ... UInt64(Self.elementCount))
        generator = Gen.zip(array, array)
        let elements = [UInt64](repeating: 1, count: Self.elementCount)
        value = (elements, elements)
        tree = try #require(try Interpreters.reflect(generator, with: value))
    }

    static func property(_ arrays: ([UInt64], [UInt64])) -> Bool {
        arrays.0.count < elementCount || arrays.1.count < elementCount
    }
}
