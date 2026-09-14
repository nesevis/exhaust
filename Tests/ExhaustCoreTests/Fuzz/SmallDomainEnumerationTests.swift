import Testing
@testable import ExhaustCore

@Suite("Small-domain enumeration")
struct SmallDomainEnumerationTests {
    @Test("An enumeration of a small leaf yields every other value of its range, each child differing at that one entry")
    func leafEnumerationCoversTheDomain() throws {
        let gen = smallLeafGenerator()
        let (parent, tree) = try materializedParent(gen.erase())
        let targets = MutationTargets(tree: tree, sequence: parent)
        #expect(targets.structuralArms.contains(.smallDomainEnumeration))
        #expect(targets.smallDomainSiteIndices.count == 2, "both four-valued leaves are enumerable, the wide one is not")
        var prng = Xoshiro256(seed: 3)
        for _ in 0 ..< 20 {
            let children = try #require(FuzzMutator.enumerateSmallDomain(parent, targets: targets, prng: &prng)).children
            #expect(children.count == 3)
            var positions = Set<Int>()
            var patterns = Set<UInt64>()
            for child in children {
                #expect(child.count == parent.count)
                let differing = child.indices.filter { child[$0] != parent[$0] }
                #expect(differing.count == 1, "child differs at \(differing.count) entries")
                if let position = differing.first {
                    positions.insert(position)
                    if case let .value(entry) = child[position] {
                        patterns.insert(entry.choice.bitPattern64)
                    }
                }
            }
            #expect(positions.count == 1, "one enumeration touched \(positions.count) sites")
            #expect(patterns.count == 3, "alternatives repeated a value")
        }
    }

    @Test("A small pick is never enumerated")
    func smallPickIsNotEnumerable() throws {
        let gen = smallPickGenerator()
        let (parent, tree) = try materializedParent(gen.erase())
        let targets = MutationTargets(tree: tree, sequence: parent)
        #expect(targets.smallDomainSiteIndices.isEmpty)
        #expect(targets.structuralArms.contains(.smallDomainEnumeration) == false)
        var prng = Xoshiro256(seed: 5)
        #expect(FuzzMutator.enumerateSmallDomain(parent, targets: targets, prng: &prng) == nil)
    }

    @Test("A wide leaf is never enumerated")
    func wideLeafIsNotEnumerable() throws {
        let leaf: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 1_000_000)
        let gen = Gen.zip(leaf, leaf)
        let (parent, tree) = try materializedParent(gen.erase())
        let targets = MutationTargets(tree: tree, sequence: parent)
        #expect(targets.smallDomainSiteIndices.isEmpty)
        #expect(targets.structuralArms.contains(.smallDomainEnumeration) == false)
        var prng = Xoshiro256(seed: 7)
        #expect(FuzzMutator.enumerateSmallDomain(parent, targets: targets, prng: &prng) == nil)
    }

    @Test("A site is enumerated once per entry: after both small leaves are marked the arm misses")
    func markedSitesAreNotWalkedAgain() throws {
        let gen = smallLeafGenerator()
        let (parent, tree) = try materializedParent(gen.erase())
        var targets = MutationTargets(tree: tree, sequence: parent)
        var prng = Xoshiro256(seed: 17)
        let first = try #require(FuzzMutator.enumerateSmallDomain(parent, targets: targets, prng: &prng))
        targets.markEnumerated(siteIndex: first.siteIndex)
        let second = try #require(FuzzMutator.enumerateSmallDomain(parent, targets: targets, prng: &prng))
        #expect(second.siteIndex != first.siteIndex)
        targets.markEnumerated(siteIndex: second.siteIndex)
        #expect(FuzzMutator.enumerateSmallDomain(parent, targets: targets, prng: &prng) == nil)
    }
}

// MARK: - Helpers

/// Two four-valued leaves and one wide leaf. The parent seed is scanned so the two small leaves hold different values.
private func smallLeafGenerator() -> Generator<(UInt64, UInt64, UInt64)> {
    let small: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 3)
    let wide: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 1_000_000)
    return Gen.zip(small, small, wide)
}

private func smallPickGenerator() -> Generator<(Any, UInt64)> {
    let first: Generator<Any> = Gen.choose(in: UInt64(0) ... 100).map { value -> Any in value }
    let second: Generator<Any> = Gen.zip(Gen.choose(in: UInt64(0) ... 100), Gen.choose(in: UInt64(0) ... 100)).map { pair -> Any in pair }
    let third: Generator<Any> = Gen.choose(in: UInt64(1000) ... 2000).map { value -> Any in value }
    let arm: Generator<Any> = Gen.pick(choices: [(1, first), (1, second), (1, third)])
    return Gen.zip(arm, Gen.choose(in: UInt64(500_000) ... 1_000_000))
}

private func materializedParent(_ gen: AnyGenerator) throws -> (ChoiceSequence, ChoiceTree) {
    for seed in UInt64(1) ... 50 {
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)
        let smallValues = sequence.compactMap { entry -> UInt64? in
            if case let .value(value) = entry, let range = value.validRange, range.count <= FuzzTunables.smallDomainLimit { return value.choice.bitPattern64 }
            return nil
        }
        if smallValues.count < 2 || smallValues[0] != smallValues[1] {
            return (sequence, tree)
        }
    }
    throw FixtureError.noSuitableParent
}

private enum FixtureError: Error {
    case noSuitableParent
}
