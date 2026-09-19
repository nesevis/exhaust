import Testing
@testable import ExhaustCore

@Suite("Materializer context initialization")
struct MaterializerContextTests {
    @Test("Exact seeds preserve conditional prefix hashing", arguments: [false, true])
    func exactSeed(materializePicks: Bool) {
        let prefix: ChoiceSequence = [
            .value(.init(choice: ChoiceValue(UInt64(7), tag: .uint64), validRange: 0 ... 10)),
        ]
        var context = Materializer.Context(prefix: prefix, mode: .exact, materializePicks: materializePicks)
        var expected = Xoshiro256(seed: materializePicks ? ZobristHash.hash(of: prefix) : 0)
        #expect(context.prng.next() == expected.next())
        #expect(context.mode == .exact)
        #expect(context.size == 100)
        #expect(context.deadlineNanoseconds == 0)
        #expect(context.shouldUseMaximumDepthForScreening == false)
    }

    @Test("Exact precomputed seeds bypass default seed selection", arguments: [false, true])
    func exactPrecomputedSeed(materializePicks: Bool) {
        var context = Materializer.Context(
            prefix: ChoiceSequence(),
            mode: .exact,
            materializePicks: materializePicks,
            precomputedSeed: 1337
        )
        var expected = Xoshiro256(seed: 1337)
        #expect(context.prng.next() == expected.next())
    }

    @Test("Guided mode preserves its seed, fallback precedence and report policy", arguments: [false, true])
    func guidedFallbackPrecedence(collectDecodingReport: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let embedded = try #require(try Interpreters.reflect(generator, with: UInt64(7)))
        let supplied = try #require(try Interpreters.reflect(generator, with: UInt64(9)))
        let context = Materializer.Context(
            prefix: ChoiceSequence(),
            mode: .guided(seed: 42, fallbackTree: embedded),
            fallbackTree: supplied,
            precomputedSeed: 1337,
            collectDecodingReport: collectDecodingReport
        )
        #expect(context.prng.seed == 42)
        #expect(context.deadlineNanoseconds == 0)
        guard case let .success(value, _, report) = Materializer.materialize(generator, context: consume context) else {
            Issue.record("Guided context failed to materialize its fallback")
            return
        }
        #expect(value == 7)
        #expect((report != nil) == collectDecodingReport)
    }

    @Test("A nil guided fallback retains the separately supplied tree")
    func suppliedFallback() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let supplied = try #require(try Interpreters.reflect(generator, with: UInt64(9)))
        let context = Materializer.Context(
            prefix: ChoiceSequence(),
            mode: .guided(seed: 42, fallbackTree: nil),
            fallbackTree: supplied
        )
        guard case let .success(value, _, _) = Materializer.materialize(generator, context: consume context) else {
            Issue.record("Guided context discarded its supplied fallback")
            return
        }
        #expect(value == 9)
    }

    @Test("Screening pins depth while honoring tree and report emission", arguments: [false, true])
    func executionPolicies(skipTree: Bool) {
        let result = Materializer.materialize(
            Gen.chooseDepth(in: UInt64(0) ... 5),
            context: .init(
                prefix: ChoiceSequence(),
                mode: .guided(seed: 42, fallbackTree: nil),
                skipTree: skipTree,
                collectDecodingReport: false,
                shouldUseMaximumDepthForScreening: true
            )
        )
        guard case let .success(value, tree, report) = result else {
            Issue.record("Screening depth materialization failed")
            return
        }
        #expect(value == 5)
        #expect(report == nil)
        switch (skipTree, tree) {
            case (true, .just):
                break
            case let (false, .choice(choice, _)):
                #expect(choice.tag == .depthControl)
                #expect(choice.bitPattern64 == value)
            default:
                Issue.record("Tree emission did not follow the requested policy")
        }
    }
}
