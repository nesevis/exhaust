import ExhaustCore
import Testing

@Suite("SprawlMutator tests")
struct SprawlMutatorTests {
    // MARK: - Low Intensity

    @Test("Low intensity preserves every structural marker in place")
    func lowIntensityPreservesStructure() throws {
        let (_, _, sequence) = try generateBindExample(seed: 11)
        var prng = Xoshiro256(seed: 42)
        let mutated = SprawlMutator.mutate(sequence, intensity: .low, prng: &prng)

        #expect(mutated.count == sequence.count)
        for index in sequence.indices {
            if case .value = sequence[index] {
                if case .value = mutated[index] {
                    continue
                }
                Issue.record("Value entry at \(index) became a structural marker")
            } else {
                #expect(mutated[index] == sequence[index])
            }
        }
        #expect(mutated != sequence)
    }

    @Test("Mutation is deterministic under a pinned seed")
    func determinism() throws {
        let (_, _, sequence) = try generateBindExample(seed: 11)
        for intensity in SprawlIntensity.allCases {
            var firstPRNG = Xoshiro256(seed: 7)
            var secondPRNG = Xoshiro256(seed: 7)
            let first = SprawlMutator.mutate(sequence, intensity: intensity, prng: &firstPRNG)
            let second = SprawlMutator.mutate(sequence, intensity: intensity, prng: &secondPRNG)
            #expect(first == second)
        }
    }

    // MARK: - Materialisation Round Trips

    @Test("Every intensity band produces a sequence the materialiser accepts", arguments: [7, 99, 1234] as [UInt64])
    func mutationsMaterialise(seed: UInt64) throws {
        let gen = bindGenerator()
        let (_, tree, sequence) = try generateBindExample(seed: seed)
        var prng = Xoshiro256(seed: seed)
        let erased = gen.erase()

        for intensity in SprawlIntensity.allCases {
            for round in 0 ..< 20 {
                let mutated = SprawlMutator.mutate(sequence, intensity: intensity, prng: &prng)
                let result = Materializer.materializeAny(
                    erased,
                    prefix: mutated,
                    mode: .guided(seed: UInt64(round) &+ seed, fallbackTree: tree)
                )
                switch result {
                    case let .success(value, _, report):
                        #expect(value is [Int])
                        let array = value as? [Int] ?? []
                        #expect(array.count >= 1 && array.count <= 5)
                        #expect(array.allSatisfy { $0 >= 0 && $0 <= 100 })
                        #expect(report != nil)
                    case .rejected, .failed:
                        Issue.record("Guided materialisation of a \(intensity) mutation was not absorbed (round \(round))")
                }
            }
        }
    }

    // MARK: - Splice

    @Test("Splice recombines two bind-bearing parents into a materialisable child")
    func spliceMaterialises() throws {
        let gen = bindGenerator()
        let (_, recipientTree, recipient) = try generateBindExample(seed: 21)
        let (_, _, donor) = try generateBindExample(seed: 22)
        var prng = Xoshiro256(seed: 5)

        let spliced = try #require(SprawlMutator.splice(recipient: recipient, donor: donor, prng: &prng))
        #expect(spliced.contains { $0 == .bind(true) })
        #expect(spliced.contains { $0 == .bind(false) })

        let result = Materializer.materializeAny(
            gen.erase(),
            prefix: spliced,
            mode: .guided(seed: 1, fallbackTree: recipientTree)
        )
        guard case let .success(value, _, _) = result else {
            Issue.record("Spliced sequence did not materialise")
            return
        }
        #expect(value is [Int])
    }

    @Test("Splice returns nil when a sequence has no bind region")
    func spliceWithoutBind() throws {
        let flatGen = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)
        var interpreter = ValueAndChoiceTreeInterpreter(flatGen, materializePicks: false, seed: 3, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())
        let flat = ChoiceSequence.flatten(tree)
        let (_, _, withBind) = try generateBindExample(seed: 21)

        var prng = Xoshiro256(seed: 5)
        #expect(SprawlMutator.splice(recipient: flat, donor: withBind, prng: &prng) == nil)
        #expect(SprawlMutator.splice(recipient: withBind, donor: flat, prng: &prng) == nil)
    }

    // MARK: - High Intensity

    /// Corruption must respect explicit, narrower-than-full ranges. Without the clamp, a random bit pattern in a bounded double slot rides the guided float clamp bypass (which exists for reflected non-finite values) straight into user closures as NaN or an out-of-range double.
    @Test("High-intensity corruption keeps explicit-range entries inside their declared range", arguments: [7, 99, 1234] as [UInt64])
    func corruptionRespectsExplicitRanges(seed: UInt64) throws {
        let gen = Gen.zip(
            Gen.choose(in: -100.0 ... 100.0 as ClosedRange<Double>),
            Gen.choose(in: 0 ... 100 as ClosedRange<Int>)
        )
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)

        var prng = Xoshiro256(seed: seed)
        var corrupted = 0
        for _ in 0 ..< 200 {
            let mutated = SprawlMutator.mutate(sequence, intensity: .high, prng: &prng)
            for (index, element) in mutated.enumerated() {
                guard case let .value(entry) = element,
                      entry.isRangeExplicit,
                      let range = entry.validRange,
                      range != entry.choice.tag.bitPatternRange
                else {
                    continue
                }
                #expect(
                    range.contains(entry.choice.bitPattern64),
                    "Corrupted entry at \(index) escaped its declared range, seed \(seed)"
                )
                if index < sequence.count, mutated[index] != sequence[index] {
                    corrupted += 1
                }
            }
        }
        #expect(corrupted > 0, "The sweep never exercised the corruption path")
    }

    // MARK: - Subtree Parsing

    @Test("subtreeEnd delimits single elements and balanced containers")
    func subtreeEndParsing() {
        let value = ChoiceSequenceValue.value(.init(
            choice: ChoiceValue(5, tag: .uint64),
            validRange: nil
        ))

        // [.bind(true), value, value, .bind(false)] — inner subtree is one element.
        let flatBind: ChoiceSequence = [.bind(true), value, value, .bind(false)]
        #expect(SprawlMutator.subtreeEnd(in: flatBind, startingAt: 1) == 2)

        // Inner subtree is a group: runs to its balanced closer.
        let groupedInner: ChoiceSequence = [.bind(true), .group(true), value, .group(false), value, .bind(false)]
        #expect(SprawlMutator.subtreeEnd(in: groupedInner, startingAt: 1) == 4)

        // Unbalanced: opener with no closer.
        let unbalanced: ChoiceSequence = [.group(true), value]
        #expect(SprawlMutator.subtreeEnd(in: unbalanced, startingAt: 0) == nil)

        // Out of range.
        #expect(SprawlMutator.subtreeEnd(in: flatBind, startingAt: 4) == nil)
    }
}

// MARK: - Helpers

/// A length-coupled array generator. `bindReified` (not the invisible monadic `bind`) creates the `.transform(.bind(...))` node whose flattening carries the `.bind(true/false)` markers splice needs.
private func bindGenerator() -> Generator<[Int]> {
    Gen.choose(in: 1 ... 5 as ClosedRange<Int>).bindReified { length in
        Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), exactly: UInt64(length))
    }
}

/// Generates one ([Int], tree, flattened sequence) example from the bind generator.
private func generateBindExample(seed: UInt64) throws -> ([Int], ChoiceTree, ChoiceSequence) {
    var interpreter = ValueAndChoiceTreeInterpreter(bindGenerator(), materializePicks: false, seed: seed, maxRuns: 1)
    guard let (value, tree) = try interpreter.next() else {
        throw MutatorTestError.generationFailed
    }
    return (value, tree, ChoiceSequence.flatten(tree))
}

private enum MutatorTestError: Error {
    case generationFailed
}
