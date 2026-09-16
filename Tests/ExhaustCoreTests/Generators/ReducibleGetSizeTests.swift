import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reducible getSize")
struct ReducibleGetSizeTests {
    @Test("The size appears in the choice tree as a pinned choice under a reified bind")
    func sizeAppearsAsPinnedChoice() throws {
        let generator = ReflectiveGenerator<UInt64>.getSize { size in
            .just(size)
        }
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 7, sizeOverride: 37)
        let (value, tree) = try #require(try interpreter.next())
        #expect(value == 37)

        guard case let .bind(_, inner, _) = tree else {
            Issue.record("Expected a bind node, got \(tree)")
            return
        }
        guard case let .choice(choice, metadata) = inner else {
            Issue.record("Expected a choice inner, got \(inner)")
            return
        }
        #expect(choice.bitPattern64 == 37)
        #expect(metadata.validRange == Gen.reducibleSizeRange)
        #expect(metadata.isPinnedToSize)
        #expect(ChoiceSequence.flatten(tree).count(where: { entry in
            guard case .value = entry else {
                return false
            }
            return true
        }) == 1)
    }

    @Test("A pinned size choice consumes no PRNG output")
    func pinnedSizeLeavesSeedStreamUntouched() throws {
        let reified = ReflectiveGenerator<UInt64>.getSize { size in
            Gen.chooseDerived(in: 0 ... size).wrapped(isReflective: true)
        }.gen
        let raw = Gen.getSize { size in
            Gen.chooseDerived(in: 0 ... size)
        }

        for seed in UInt64(1) ... 20 {
            var reifiedInterpreter = ValueAndChoiceTreeInterpreter(reified, seed: seed, sizeOverride: 50)
            var rawInterpreter = ValueAndChoiceTreeInterpreter(raw, seed: seed, sizeOverride: 50)
            let reifiedValues = try reifiedInterpreter.prefix(5).map(\.value)
            let rawValues = try rawInterpreter.prefix(5).map(\.value)
            #expect(reifiedValues == rawValues, "seed \(seed)")
        }
    }

    @Test("The reducer lowers the size to the smallest failing value")
    func reducerLowersSize() throws {
        let generator = ReflectiveGenerator<UInt64>.getSize { size in
            .just(size)
        }
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 7, sizeOverride: 37)
        let (value, tree) = try #require(try interpreter.next())
        try #require(value == 37)

        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: generator.gen,
            tree: tree,
            output: value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            property: { $0 < 10 }
        )

        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == 10)
    }

    /// The bound subtree of a bind is opaque to screening, as it was before the size became a choice, and the pinned size must not become a parameter of its own: analysis finds nothing to screen.
    @Test("Screening analysis does not enumerate the size")
    func screeningSkipsPinnedSize() {
        let generator = ReflectiveGenerator<UInt64>.getSize { _ in
            Gen.chooseDerived(in: 0 ... 3).wrapped(isReflective: true)
        }
        #expect(ChoiceTreeAnalysis.analyze(generator.gen) == nil)
    }

    @Test("Screening preserves pinned sizes beside independent choices", arguments: [UInt64(3), 1000])
    func screeningReplaysPinnedSize(upperBound: UInt64) throws {
        let size = ReflectiveGenerator<UInt64>.getSize { .just($0) }.resize(37).gen
        let generator = Gen.zip(size, Gen.choose(in: UInt64(0) ... upperBound), size)
        let analysis = try #require(ChoiceTreeAnalysis.analyze(generator))
        let profile: any ScreeningProfile = switch analysis {
            case let .enumerable(profile):
                profile
            case let .large(profile):
                profile
        }
        #expect(profile.parameterCount == 1)
        for valueIndex in UInt64(0) ..< profile.domainSizes[0] {
            let row = CoveringArrayRow(values: [valueIndex])
            let tree = try #require(profile.buildTree(from: row))
            let replayed = try #require(try Interpreters.replay(generator, using: tree))
            #expect(replayed.0 == 37)
            #expect(replayed.2 == 37)
            let materialized: (value: (UInt64, UInt64, UInt64), tree: ChoiceTree) = try #require(
                ScreeningRunner.materializeRow(
                    generator.erase(), row: row, rowIndex: Int(valueIndex), profile: profile, needsTree: true
                )
            )
            #expect(materialized.value == replayed)
        }
    }

    @Test("Resize above the declared range clamps the pinned size")
    func resizeClampsPinnedSize() throws {
        let generator = ReflectiveGenerator<UInt64>.getSize { size in
            .just(size)
        }.resize(500)
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 7)
        let (value, _) = try #require(try interpreter.next())
        #expect(value == Gen.reducibleSizeRange.upperBound)
    }
}
