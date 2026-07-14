import Testing
@testable import ExhaustCore

@Suite("Materializer tree-construction parity")
struct MaterializerTreeConstructionParityTests {
    @Test("Exact materialisation has tree-construction parity", arguments: [false, true])
    func exactMaterialisationParity(materializePicks: Bool) throws {
        let generator = makeParityGenerator()
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: true,
            seed: 1337,
            maxRuns: 20
        )
        var testedValueCount = 0

        while let (_, tree) = try interpreter.next() {
            let candidate = ChoiceSequence(tree)
            try assertTreeConstructionParity(
                generator,
                prefix: candidate,
                mode: .exact,
                fallbackTree: tree,
                materializePicks: materializePicks,
                precomputedSeed: ZobristHash.hash(of: candidate)
            )
            testedValueCount += 1
        }

        #expect(testedValueCount == 20)
    }

    @Test("Guided fallback has tree-construction parity", arguments: [false, true])
    func guidedFallbackParity(materializePicks: Bool) throws {
        let generator = makeParityGenerator()
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: true,
            seed: 2021,
            maxRuns: 10
        )
        var testedValueCount = 0

        while let (_, tree) = try interpreter.next() {
            try assertTreeConstructionParity(
                generator,
                prefix: ChoiceSequence(),
                mode: .guided(seed: 9001, fallbackTree: tree),
                fallbackTree: tree,
                materializePicks: materializePicks
            )
            testedValueCount += 1
        }

        #expect(testedValueCount == 10)
    }

    @Test("Guided PRNG fallback has tree-construction parity")
    func guidedPRNGFallbackParity() throws {
        let generator = makeParityGenerator()

        for seed in [UInt64(0), 1, 42, 1337, UInt64.max] {
            for materializePicks in [false, true] {
                try assertTreeConstructionParity(
                    generator,
                    prefix: ChoiceSequence(),
                    mode: .guided(seed: seed, fallbackTree: nil),
                    fallbackTree: nil,
                    materializePicks: materializePicks
                )
            }
        }
    }
}

private func makeParityGenerator() -> Generator<[UInt64]> {
    let elementGenerator = Gen.pick(choices: [
        (1, Gen.choose(in: UInt64(0) ... 100)),
        (2, Gen.choose(in: UInt64(101) ... 200)),
    ])

    return Gen.choose(in: UInt64(1) ... 5).bind { elementCount in
        Gen.arrayOf(elementGenerator, exactly: elementCount)
    }
}

private func assertTreeConstructionParity<Output: Equatable>(
    _ generator: Generator<Output>,
    prefix: ChoiceSequence,
    mode: Materializer.Mode,
    fallbackTree: ChoiceTree?,
    materializePicks: Bool,
    precomputedSeed: UInt64? = nil
) throws {
    let valueOnlyResult = Materializer.materializeAny(
        generator.erase(),
        prefix: prefix,
        mode: mode,
        fallbackTree: fallbackTree,
        materializePicks: false,
        precomputedSeed: precomputedSeed,
        skipTree: true
    )
    let treeBuildingResult = Materializer.materializeAny(
        generator.erase(),
        prefix: prefix,
        mode: mode,
        fallbackTree: fallbackTree,
        materializePicks: materializePicks,
        precomputedSeed: precomputedSeed
    )

    guard case let .success(valueOnlyOutput, valueOnlyTree, _) = valueOnlyResult else {
        Issue.record("Value-only materialisation did not succeed")
        return
    }
    guard case let .success(treeBuildingOutput, _, _) = treeBuildingResult else {
        Issue.record("Tree-building materialisation did not succeed")
        return
    }
    guard case .just = valueOnlyTree else {
        Issue.record("Value-only materialisation unexpectedly constructed a tree")
        return
    }

    let valueWithoutTree = try #require(valueOnlyOutput as? Output)
    let valueWithTree = try #require(treeBuildingOutput as? Output)
    #expect(valueWithoutTree == valueWithTree)
}
