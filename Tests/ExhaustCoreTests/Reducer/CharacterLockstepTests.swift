import Testing
@testable import ExhaustCore

@Suite("Character lockstep")
struct CharacterLockstepTests {
    @Test("Lockstep proposes narrower UTF-8 boundaries across every matching occurrence", arguments: [UInt32(0x80), 0x800])
    func reducesWidth(target: UInt32) throws {
        let generator = Gen.eachOf(Array(repeating: Gen.character().gen, count: 6))
        let initial = Array(repeating: Character("\u{10000}"), count: 6)
        let expected = Array(repeating: Character(Unicode.Scalar(target)!), count: 6)
        var machine = try ReductionMachine(
            gen: generator,
            initialTree: #require(try Interpreters.reflect(generator, with: initial)),
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.lockstep]),
            collectStats: true,
            property: { $0 != initial && $0 != expected }
        )
        while machine.next() != nil {}
        #expect(machine.output as? [Character] == expected)
    }

    @Test("Every matching occurrence changes, including interleaved groups larger than four", arguments: [2, 5, 64])
    func allOccurrences(count: Int) throws {
        let generator = Gen.eachOf(Array(repeating: Gen.character().gen, count: count * 2))
        let initial = (0 ..< count * 2).map { $0.isMultiple(of: 2) ? Character("å") : Character(".") }
        var (encoder, candidate) = try encoder(generator: generator, initial: initial)
        let expected = initial.map { $0 == "å" ? Character("A") : $0 }
        var found = false
        while let probe = encoder.nextProbe(into: &candidate, lastAccepted: false) {
            if try materialize(generator, candidate) == expected {
                guard case let .leafValues(changes) = probe else {
                    Issue.record("Expected a value mutation")
                    return
                }
                #expect(changes.count == count)
                found = true
                break
            }
        }
        #expect(found)
    }

    @Test("An accepted simplification is never restored by a later character proposal")
    func acceptedBaseline() throws {
        let generator = Gen.eachOf(Array(repeating: Gen.character().gen, count: 6))
        let initial = Array(repeating: Character("å"), count: 6)
        var (encoder, candidate) = try encoder(generator: generator, initial: initial)
        let expected = Array(repeating: Character("A"), count: 6)
        let baseline = try ChoiceSequence.flatten(#require(try Interpreters.reflect(generator, with: expected)))
        var accepted = false
        var lastAccepted = false
        while encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted) != nil {
            let values = try materialize(generator, candidate)
            if accepted {
                // All subsequent index shifts must also improve the accepted sequence.
                #expect(candidate.shortLexPrecedes(baseline))
            }
            lastAccepted = values == expected
            accepted = accepted || lastAccepted
        }
        #expect(accepted)
    }

    @Test("Uniform proposals partition identical indices by character map", arguments: [false, true])
    func distinctDomains(differentBottom: Bool) throws {
        let first = Gen.character(in: "a" ... "z").gen
        let second = differentBottom
            ? Gen.character(in: "a" ... "z", simplest: "z").gen
            : Gen.character(in: "A" ... "Z").gen
        let generator = Gen.eachOf([first, first, second, second])
        let initial: [Character] = differentBottom ? ["y", "y", "y", "y"] : ["y", "y", "Y", "Y"]
        var (encoder, candidate) = try encoder(generator: generator, initial: initial)
        #expect(encoder.nextProbe(into: &candidate, lastAccepted: false) != nil)
        #expect(try materialize(generator, candidate) == ["a", "a", initial[2], initial[3]])
        #expect(encoder.nextProbe(into: &candidate, lastAccepted: false) != nil)
        let target: Character = differentBottom ? "z" : "A"
        #expect(try materialize(generator, candidate) == [initial[0], initial[1], target, target])
    }

    @Test("Numeric lockstep candidates precede character proposals even when characters occur first")
    func numericPriority() throws {
        let characters = Gen.eachOf(Array(repeating: Gen.character().gen, count: 2))
        let numbers = Gen.eachOf(Array(repeating: Gen.choose(in: 0 ... 100), count: 2))
        let generator = Gen.zip(characters, numbers)
        let tree = try #require(try Interpreters.reflect(generator, with: ([Character("å"), "å"], [12, 12])))
        var (encoder, candidate) = try encoder(tree: tree)
        #expect(encoder.nextProbe(into: &candidate, lastAccepted: false) != nil)
        guard case let .success(values, _, _) = Materializer.materialize(generator, context: .init(prefix: candidate, mode: .exact)) else {
            Issue.record("Mixed candidate must materialize exactly")
            return
        }
        #expect(values.0 == ["å", "å"])
        #expect(values.1 == [0, 0])
    }

    @Test("Lockstep alone reaches a shared letter simplification")
    func reducesWithoutStagedSearch() throws {
        let generator = Gen.eachOf(Array(repeating: Gen.character().gen, count: 8))
        let initial = Array(repeating: Character("å"), count: 8)
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.lockstep]),
            collectStats: true,
            property: { values in
                values[0].isLetter == false || values.contains { $0 != values[0] }
            }
        )
        while machine.next() != nil {}
        #expect(machine.output as? [Character] == Array(repeating: Character("A"), count: 8))
        #expect(machine.stats.encoderCounts[.lockstep]?.accepted ?? 0 > 0)
    }

    private func encoder(generator: Generator<[Character]>, initial: [Character]) throws -> (GraphLockstepEncoder, ChoiceSequence) {
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        return try encoder(tree: tree)
    }

    private func encoder(tree: ChoiceTree) throws -> (GraphLockstepEncoder, ChoiceSequence) {
        let graph = ChoiceGraph.build(from: tree)
        let scope = try #require(ExchangeQuery.build(graph: graph).tandemScope)
        let sequence = ChoiceSequence.flatten(tree)
        var encoder = GraphLockstepEncoder()
        encoder.start(scope: .init(
            transformation: .init(
                operation: .exchange(.tandem(scope)),
                priority: .init(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 1, estimatedCost: 1)
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        ))
        return (encoder, sequence)
    }

    private func materialize(_ generator: Generator<[Character]>, _ sequence: ChoiceSequence) throws -> [Character] {
        guard case let .success(values, _, _) = Materializer.materialize(generator, context: .init(prefix: sequence, mode: .exact)) else {
            Issue.record("Character candidate must materialize exactly")
            return []
        }
        return values
    }
}
