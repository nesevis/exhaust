import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Terminal lift size ceiling")
struct TerminalLiftSizeTests {
    @Test("Bounded lifts exist exactly when the selected history fits")
    func generatedCeilings() throws {
        try exhaustCheck(Gen.zip(Gen.choose(in: 0 ... 64), Gen.choose(in: 0 ... 140))) { length, ceiling in
            let array = Gen.arrayOf(Gen.choose(in: 0 ... 1), exactly: UInt64(length))
            let generator = Gen.zip(array, array).erase()
            guard let unrestricted = Materializer.guidedLift(
                generator: generator,
                prefix: [],
                fallbackTree: .just
            ) else {
                return false
            }
            let fits = unrestricted.flattenedEntryCount <= ceiling
            guard let bounded = Materializer.guidedLift(
                generator: generator,
                prefix: [],
                fallbackTree: .just,
                maximumSequenceCount: ceiling
            ) else {
                return fits == false
            }
            return fits && ChoiceSequence(bounded) == ChoiceSequence(unrestricted)
        }
    }

    @Test("Oversized scalar arrays reject before resolving any elements")
    func rejectsBeforeElements() throws {
        let generator = Gen.arrayOf(Gen.choose(in: 0 ... 1), exactly: 100_000)
        let result = Materializer.materializeAny(
            generator.erase(),
            context: .init(
                prefix: [
                    .sequence(true, validRange: 100_000 ... 100_000, isLengthExplicit: true),
                    .sequence(false),
                ],
                mode: .guided(seed: 0, fallbackTree: nil),
                maximumSequenceCount: 71
            )
        )
        guard case let .rejected(report) = result else {
            Issue.record("Expected early size rejection")
            return
        }
        #expect(try #require(report).totalCount == 0)
    }

    @Test("Equal-length histories remain admissible and unrestricted lifts can grow")
    func boundaryAndGrowth() throws {
        let generator = Gen.arrayOf(Gen.choose(in: 0 ... 1), exactly: 24).erase()
        let unrestricted = try #require(Materializer.guidedLift(
            generator: generator,
            prefix: [],
            fallbackTree: .just
        ))
        let count = ChoiceSequence(unrestricted).count
        let equal = try #require(Materializer.guidedLift(
            generator: generator,
            prefix: [],
            fallbackTree: .just,
            maximumSequenceCount: count
        ))
        #expect(ChoiceSequence(equal) == ChoiceSequence(unrestricted))
        #expect(Materializer.guidedLift(
            generator: generator,
            prefix: [],
            fallbackTree: .just,
            maximumSequenceCount: count - 1
        ) == nil)
    }

    @Test("An oversized unsuccessful audition can yield to a smaller arm")
    func backtrackAudition() throws {
        let large = Gen.arrayOf(Gen.choose(in: 0 ... 1), exactly: 100).map { _ in Int?.none }
        let generator: Generator<Int> = Gen.backtrack(always: [(1, large), (1, Gen.just(Int?(7)))])
        let prefix: ChoiceSequence = [
            .group(true),
            .branch(.init(id: 0, branchCount: 2, fingerprint: 0)),
        ]
        let unrestricted = try #require(Materializer.guidedLift(
            generator: generator.erase(),
            prefix: prefix,
            fallbackTree: .just
        ))
        let bounded = try #require(Materializer.guidedLift(
            generator: generator.erase(),
            prefix: prefix,
            fallbackTree: .just,
            maximumSequenceCount: ChoiceSequence(unrestricted).count
        ))
        #expect(ChoiceSequence(bounded) == ChoiceSequence(unrestricted))
    }

    @Test("Combined subtrees still obey the complete-history ceiling")
    func combinedSubtrees() {
        let array = Gen.arrayOf(Gen.choose(in: 0 ... 1), exactly: 10)
        let generator = Gen.zip(array, array).erase()
        #expect(Materializer.guidedLift(
            generator: generator,
            prefix: [],
            fallbackTree: .just,
            maximumSequenceCount: 20
        ) == nil)
        #expect(Materializer.guidedLift(
            generator: generator,
            prefix: [],
            fallbackTree: .just
        ) != nil)
    }
}
