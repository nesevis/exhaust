import Testing
@testable import ExhaustCore

@Suite("Element transplant")
struct ElementTransplantTests {
    @Test("A copy grows the target by the run and leaves the donor unchanged, within the target's length bound")
    func copyGrowsTargetWithinBound() throws {
        let gen = twoListsGenerator()
        let (parent, tree) = try materializedParent(gen)
        let targets = MutationTargets(tree: tree, sequence: parent)
        #expect(targets.structuralArms.contains(.elementTransplant))
        #expect(targets.transplantGroups.count == 1)
        var prng = Xoshiro256(seed: 3)
        var grown = 0
        for seed in UInt64(1) ... 40 {
            guard let child = FuzzMutator.transplantElementRun(parent, targets: targets, mode: .copy, prng: &prng) else { continue }
            let before = try #require(lists(gen, parent, tree, seed: seed))
            let after = try #require(lists(gen, child, tree, seed: seed))
            let total = before.0.count + before.1.count
            #expect(after.0.count + after.1.count > total, "copy did not grow the pair")
            #expect(after.0.count <= 4 && after.1.count <= 4, "a list exceeded its bound: \(after)")
            #expect(after.0 == before.0 || after.1 == before.1, "copy changed both lists")
            #expect(markersBalanced(child))
            grown += 1
        }
        #expect(grown > 0)
    }

    @Test("A move keeps the total element count and shrinks the donor by the run")
    func moveConservesElements() throws {
        let gen = twoListsGenerator()
        let (parent, tree) = try materializedParent(gen)
        let targets = MutationTargets(tree: tree, sequence: parent)
        var prng = Xoshiro256(seed: 5)
        var moved = 0
        for seed in UInt64(1) ... 40 {
            guard let child = FuzzMutator.transplantElementRun(parent, targets: targets, mode: .move, prng: &prng) else { continue }
            let before = try #require(lists(gen, parent, tree, seed: seed))
            let after = try #require(lists(gen, child, tree, seed: seed))
            #expect(after.0.count + after.1.count == before.0.count + before.1.count, "move changed the element total")
            #expect((after.0 + after.1).sorted() == (before.0 + before.1).sorted(), "move changed the multiset of elements")
            #expect(after.0.count <= 4 && after.1.count <= 4)
            #expect(markersBalanced(child))
            if after.0.count != before.0.count { moved += 1 }
        }
        #expect(moved > 0)
    }

    @Test("Lists of different element sites are never paired")
    func differentSitesAreNotPaired() throws {
        let a: Generator<[UInt64]> = Gen.arrayOf(elementPick(), within: 1 ... 4, scaling: .constant)
        let b: Generator<[UInt64]> = Gen.arrayOf(otherPick(), within: 1 ... 4, scaling: .constant)
        let gen = Gen.zip(a, b)
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: 9, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())
        let targets = MutationTargets(tree: tree, sequence: ChoiceSequence.flatten(tree))
        #expect(targets.transplantGroups.isEmpty)
        #expect(targets.structuralArms.contains(.elementTransplant) == false)
    }
}

// MARK: - Helpers

/// One pick site for every element of both lists, so the lists share an element site.
private func elementPick() -> Generator<UInt64> {
    Gen.pick(choices: [(1, Gen.choose(in: UInt64(0) ... 9)), (1, Gen.choose(in: UInt64(100) ... 109))])
}

private func otherPick() -> Generator<UInt64> {
    Gen.pick(choices: [(1, Gen.choose(in: UInt64(0) ... 9)), (1, Gen.choose(in: UInt64(100) ... 109))])
}

private func twoListsGenerator() -> Generator<([UInt64], [UInt64])> {
    let a: Generator<[UInt64]> = Gen.arrayOf(elementPick(), within: 0 ... 4, scaling: .constant)
    let b: Generator<[UInt64]> = Gen.arrayOf(elementPick(), within: 0 ... 4, scaling: .constant)
    return Gen.zip(a, b)
}

/// A parent with elements in both lists and room left in each.
private func materializedParent(_ gen: Generator<([UInt64], [UInt64])>) throws -> (ChoiceSequence, ChoiceTree) {
    for seed in UInt64(1) ... 200 {
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 1)
        let (value, tree) = try #require(try interpreter.next())
        if (1 ... 3).contains(value.0.count), (1 ... 3).contains(value.1.count) {
            return (ChoiceSequence.flatten(tree), tree)
        }
    }
    throw FixtureError.noSuitableParent
}

private func lists(_ gen: Generator<([UInt64], [UInt64])>, _ sequence: ChoiceSequence, _ tree: ChoiceTree, seed: UInt64) -> ([UInt64], [UInt64])? {
    guard case let .success(value, _, _) = Materializer.materializeAnyFlat(gen.erase(), prefix: sequence, mode: .guided(seed: seed, fallbackTree: tree)) else {
        return nil
    }
    return value as? ([UInt64], [UInt64])
}

private func markersBalanced(_ sequence: ChoiceSequence) -> Bool {
    var depth = 0
    for entry in sequence {
        switch entry {
            case .group(true), .zip(true), .bind(true), .sequence(true, _, _):
                depth += 1
            case .group(false), .zip(false), .bind(false), .sequence(false, _, _):
                depth -= 1
                if depth < 0 { return false }
            default:
                break
        }
    }
    return depth == 0
}

private enum FixtureError: Error {
    case noSuitableParent
}
