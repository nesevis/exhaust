import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Materializer prefix pick observation")
struct MaterializerPrefixPickObservationTests {
    @Test("Exact replay reports every committed pick at its branch entry with the selected arm")
    func exactReplayReportsCommittedPicks() throws {
        var interpreter = ValueAndChoiceTreeInterpreter(nestedPickGenerator, seed: 0x9C1C_4B0E, maxRuns: 40)
        var observedPickCount = 0
        while let draw = try interpreter.next() {
            let sequence = ChoiceSequence.flatten(draw.tree)
            let observations = try exactObservations(of: nestedPickGenerator.erase(), replaying: sequence)
            observedPickCount += observations.count

            let expected = branchEntries(in: sequence)
            #expect(observations.map(\.branchIndex) == expected.map(\.index))
            #expect(observations.map(\.selectedIndex) == expected.map(\.selectedIndex))
            #expect(observations.map(\.choices.count) == expected.map(\.branchCount))
        }
        #expect(observedPickCount > 0)
    }

    @Test("Exact replay does not report backtrack picks")
    func exactReplaySkipsBacktrackPicks() throws {
        let generator: Generator<Int> = Gen.backtrack(always: [
            (1, Gen.choose(in: 0 ... 9).map { $0 < 5 ? $0 : nil }),
            (1, Gen.choose(in: 100 ... 109).liftToOptional()),
        ])
        var interpreter = ValueAndChoiceTreeInterpreter(generator, seed: 0x9C1C_4B0E, maxRuns: 20)
        var replayCount = 0
        while let draw = try interpreter.next() {
            let sequence = ChoiceSequence.flatten(draw.tree)
            let observations = try exactObservations(of: generator.erase(), replaying: sequence)
            #expect(observations.isEmpty)
            replayCount += 1
        }
        #expect(replayCount > 0)
    }

    @Test("Guided replay does not report picks")
    func guidedReplayReportsNothing() throws {
        var interpreter = ValueAndChoiceTreeInterpreter(nestedPickGenerator, seed: 0x9C1C_4B0E, maxRuns: 20)
        var replayCount = 0
        while let draw = try interpreter.next() {
            var observations: [Materializer.PrefixPickObservation] = []
            var context = Materializer.Context(
                prefix: ChoiceSequence.flatten(draw.tree),
                mode: .guided(seed: 0, fallbackTree: draw.tree)
            )
            context.observePrefixPick = { observations.append($0) }
            guard case .success = Materializer.materializeAny(nestedPickGenerator.erase(), context: context) else {
                Issue.record("Guided replay of a drawn sequence failed")
                return
            }
            #expect(observations.isEmpty)
            replayCount += 1
        }
        #expect(replayCount > 0)
    }
}

// MARK: - Helpers

/// Picks inside a sequence, a pick nested in a pick arm, and a choice-free arm, so branch entries sit at varied depths.
private let nestedPickGenerator: Generator<([UInt64], UInt64)> = Gen.zip(
    Gen.arrayOf(
        Gen.pick(choices: [
            (1, Gen.just(UInt64(7))),
            (1, Gen.choose(in: UInt64(0) ... 5)),
            (1, Gen.choose(in: UInt64(10) ... 20)),
        ]),
        within: 0 ... 4
    ),
    Gen.pick(choices: [
        (1, Gen.pick(choices: [
            (1, Gen.just(UInt64(1))),
            (1, Gen.choose(in: UInt64(2) ... 9)),
        ])),
        (1, Gen.choose(in: UInt64(100) ... 200)),
    ])
)

private func exactObservations(
    of generator: AnyGenerator,
    replaying sequence: ChoiceSequence
) throws -> [Materializer.PrefixPickObservation] {
    var observations: [Materializer.PrefixPickObservation] = []
    var context = Materializer.Context(prefix: sequence, mode: .exact, skipTree: true, collectDecodingReport: false)
    context.observePrefixPick = { observations.append($0) }
    guard case .success = Materializer.materializeAny(generator, context: context) else {
        Issue.record("Exact replay of a drawn sequence failed")
        return []
    }
    return observations
}

private func branchEntries(in sequence: ChoiceSequence) -> [(index: Int, selectedIndex: Int, branchCount: Int)] {
    sequence.enumerated().compactMap { index, entry in
        guard case let .branch(branch) = entry else {
            return nil
        }
        return (index, Int(branch.id), Int(branch.branchCount))
    }
}
