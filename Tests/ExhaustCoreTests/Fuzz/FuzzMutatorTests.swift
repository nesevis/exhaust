import ExhaustCore
import Foundation
import Testing

@Suite("FuzzMutator tests")
struct FuzzMutatorTests {
    // MARK: - Low Intensity

    @Test("Low intensity preserves every structural marker in place")
    func lowIntensityPreservesStructure() throws {
        let (_, _, sequence) = try generateBindExample(seed: 11)
        var prng = Xoshiro256(seed: 42)
        let mutated = FuzzMutator.mutate(sequence, intensity: .low, prng: &prng)

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
        for intensity in MutationIntensity.allCases {
            var firstPRNG = Xoshiro256(seed: 7)
            var secondPRNG = Xoshiro256(seed: 7)
            let first = FuzzMutator.mutate(sequence, intensity: intensity, prng: &firstPRNG)
            let second = FuzzMutator.mutate(sequence, intensity: intensity, prng: &secondPRNG)
            #expect(first == second)
        }
    }

    @Test("Cached mutation layout preserves results and PRNG consumption")
    func cachedLayoutParity() throws {
        let (_, tree, sequence) = try generateBindExample(seed: 11)
        let layout = FuzzMutator.layout(of: sequence, tree: tree)

        for intensity in MutationIntensity.allCases {
            var uncachedPRNG = Xoshiro256(seed: 7)
            var cachedPRNG = Xoshiro256(seed: 7)
            for _ in 0 ..< 50 {
                let uncached = FuzzMutator.mutate(
                    sequence,
                    intensity: intensity,
                    prng: &uncachedPRNG
                )
                let cached = FuzzMutator.mutate(
                    sequence,
                    intensity: intensity,
                    layout: layout,
                    prng: &cachedPRNG
                )
                #expect(cached == uncached)
                #expect(cachedPRNG.currentState == uncachedPRNG.currentState)
            }
        }

        var uncachedPRNG = Xoshiro256(seed: 9)
        var cachedPRNG = Xoshiro256(seed: 9)
        for _ in 0 ..< 50 {
            let uncached = FuzzMutator.splice(
                recipient: sequence,
                donor: sequence,
                prng: &uncachedPRNG
            )
            let cached = FuzzMutator.splice(
                recipient: sequence,
                donor: sequence,
                recipientLayout: layout,
                donorLayout: layout,
                prng: &cachedPRNG
            )
            #expect(cached == uncached)
            #expect(cachedPRNG.currentState == uncachedPRNG.currentState)
        }
    }

    @Test("Layout catalog carries the character payload's problematic indices")
    func layoutCatalogUsesCharacterPayload() throws {
        // Sequence entries do not carry the TypeTagPayload, so without the tree the character catalog degrades to the [min, max] fallback and mutation-phase boundary substitution loses the interesting in-set characters.
        let characterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        var interpreter = ValueAndChoiceTreeInterpreter(
            Gen.character(from: characterSet).gen,
            materializePicks: false,
            seed: 1,
            maxRuns: 1
        )
        guard let (_, tree) = try interpreter.next() else {
            throw MutatorTestError.generationFailed
        }

        let expected = try #require(characterPayloadIndices(in: tree))
        #expect(expected.isEmpty == false)

        let layout = FuzzMutator.layout(of: ChoiceSequence.flatten(tree), tree: tree)
        let catalogEntry = try #require(layout.problematicValues.first { $0.key.tag == .character })
        #expect(catalogEntry.value == expected)
    }

    // MARK: - Materialization Round Trips

    @Test("Every intensity band produces a sequence the materializer accepts", arguments: [7, 99, 1234] as [UInt64])
    func mutationsMaterialise(seed: UInt64) throws {
        let gen = bindGenerator()
        let (_, tree, sequence) = try generateBindExample(seed: seed)
        var prng = Xoshiro256(seed: seed)
        let erased = gen.erase()

        for intensity in MutationIntensity.allCases {
            for round in 0 ..< 20 {
                let mutated = FuzzMutator.mutate(sequence, intensity: intensity, prng: &prng)
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
                        Issue.record("Guided materialization of a \(intensity) mutation was not absorbed (round \(round))")
                }
            }
        }
    }

    // MARK: - Splice

    @Test("Splice recombines two bind-bearing parents into a materializable child")
    func spliceMaterialises() throws {
        let gen = bindGenerator()
        let (_, recipientTree, recipient) = try generateBindExample(seed: 21)
        let (_, _, donor) = try generateBindExample(seed: 22)
        var prng = Xoshiro256(seed: 5)

        let spliced = try #require(FuzzMutator.splice(recipient: recipient, donor: donor, prng: &prng))
        #expect(spliced.contains { $0 == .bind(true) })
        #expect(spliced.contains { $0 == .bind(false) })

        let result = Materializer.materializeAny(
            gen.erase(),
            prefix: spliced,
            mode: .guided(seed: 1, fallbackTree: recipientTree)
        )
        guard case let .success(value, _, _) = result else {
            Issue.record("Spliced sequence did not materialize")
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
        #expect(FuzzMutator.splice(recipient: flat, donor: withBind, prng: &prng) == nil)
        #expect(FuzzMutator.splice(recipient: withBind, donor: flat, prng: &prng) == nil)
    }

    @Test("Splice handles deeply nested bind regions deterministically")
    func spliceDeeplyNestedBinds() throws {
        let sequence = nestedBindSequence(depth: 128)
        var firstPRNG = Xoshiro256(seed: 5)
        var secondPRNG = Xoshiro256(seed: 5)

        let first = try #require(FuzzMutator.splice(
            recipient: sequence,
            donor: sequence,
            prng: &firstPRNG
        ))
        let second = try #require(FuzzMutator.splice(
            recipient: sequence,
            donor: sequence,
            prng: &secondPRNG
        ))

        #expect(first == second)
        #expect(ChoiceSequence.validate(first))
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
            let mutated = FuzzMutator.mutate(sequence, intensity: .high, prng: &prng)
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
        #expect(flatBind.subtreeEnd(startingAt: 1) == 2)

        // Inner subtree is a group: runs to its balanced closer.
        let groupedInner: ChoiceSequence = [.bind(true), .group(true), value, .group(false), value, .bind(false)]
        #expect(groupedInner.subtreeEnd(startingAt: 1) == 4)

        // Unbalanced: opener with no closer.
        let unbalanced: ChoiceSequence = [.group(true), value]
        #expect(unbalanced.subtreeEnd(startingAt: 0) == nil)

        // Out of range.
        #expect(flatBind.subtreeEnd(startingAt: 4) == nil)
    }
}

// MARK: - Helpers

/// A length-coupled array generator. `bindReified` (not the invisible monadic `bind`) creates the `.transform(.bind(...))` node whose flattening carries the `.bind(true/false)` markers splice needs.
private func bindGenerator() -> Generator<[Int]> {
    Gen.choose(in: 1 ... 5 as ClosedRange<Int>).bindReified { length in
        Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), exactly: UInt64(length))
    }
}

private func nestedBindSequence(depth: Int) -> ChoiceSequence {
    let value = ChoiceSequenceValue.value(.init(
        choice: ChoiceValue(0, tag: .uint64),
        validRange: 0 ... UInt64.max,
        isRangeExplicit: true
    ))
    var sequence = ChoiceSequence()
    sequence.reserveCapacity(depth * 3 + 1)
    sequence.append(contentsOf: repeatElement(.bind(true), count: depth))
    sequence.append(value)
    for _ in 0 ..< depth {
        sequence.append(value)
        sequence.append(.bind(false))
    }
    return sequence
}

/// Generates one ([Int], tree, flattened sequence) example from the bind generator.
private func generateBindExample(seed: UInt64) throws -> ([Int], ChoiceTree, ChoiceSequence) {
    var interpreter = ValueAndChoiceTreeInterpreter(bindGenerator(), materializePicks: false, seed: seed, maxRuns: 1)
    guard let (value, tree) = try interpreter.next() else {
        throw MutatorTestError.generationFailed
    }
    return (value, tree, ChoiceSequence.flatten(tree))
}

/// Finds the first character choice in the tree and returns its payload's problematic indices.
private func characterPayloadIndices(in tree: ChoiceTree) -> [UInt64]? {
    switch tree {
        case let .choice(_, metadata):
            guard case let .character(problematicIndices) = metadata.typeTagPayload else {
                return nil
            }
            return problematicIndices
        case .just, .getSize:
            return nil
        case let .sequence(elements, _):
            return elements.lazy.compactMap(characterPayloadIndices(in:)).first
        case let .group(elements, _):
            return elements.lazy.compactMap(characterPayloadIndices(in:)).first
        case let .branch(branch):
            return characterPayloadIndices(in: branch.choice)
        case let .resize(_, choices):
            return choices.lazy.compactMap(characterPayloadIndices(in:)).first
        case let .bind(_, inner, bound):
            return characterPayloadIndices(in: inner) ?? characterPayloadIndices(in: bound)
    }
}

private enum MutatorTestError: Error {
    case generationFailed
}
