import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Element run operators")
struct ElementRunOperatorTests {
    @Test("Run deletion removes whole consecutive elements and keeps the rest in order")
    func runDeletionRemovesConsecutiveElements() throws {
        let fixture = try runFixture()
        var prng = Xoshiro256(seed: 3)
        var shortened = 0
        for _ in 0 ..< 30 {
            guard let child = FuzzMutator.deleteElementRun(fixture.sequence, targets: fixture.targets, prng: &prng) else {
                continue
            }
            let parentValues = values(of: fixture.sequence)
            let childValues = values(of: child)
            #expect(childValues.count < parentValues.count)
            #expect(isSubsequence(childValues, of: parentValues), "deletion did not keep the surviving elements in order")
            #expect(markersBalanced(child))
            shortened += 1
        }
        #expect(shortened > 0)
    }

    @Test("Deletion yields a shorter subsequence with balanced markers, over generated parent and mutator seeds")
    func runDeletionIsASubsequenceOverSeeds() throws {
        let seeds = Gen.zip(Gen.choose(in: UInt64(1) ... 10000), Gen.choose(in: UInt64(1) ... 10000))
        let deletions = DeletionCounter()
        try exhaustCheck(seeds, maxIterations: 300) { (pair: (UInt64, UInt64)) throws -> Bool in
            let (parentSeed, mutatorSeed) = pair
            let (sequence, tree) = try materializedParent(arrayThenLeafGenerator(), seed: parentSeed)
            var prng = Xoshiro256(seed: mutatorSeed)
            let parentValues = values(of: sequence)
            guard let child = FuzzMutator.deleteElementRun(sequence, targets: MutationTargets(tree: tree), prng: &prng) else {
                // The array's minimum length is one, so a parent holding a single element plus the trailing leaf has no run the operator may remove.
                return parentValues.count <= 2
            }
            deletions.increment()
            let childValues = values(of: child)
            return childValues.count < parentValues.count
                && isSubsequence(childValues, of: parentValues)
                && markersBalanced(child)
        }
        #expect(deletions.total > 0, "no seed pair produced a deletion")
    }

    @Test("Run duplication repeats a run immediately after itself")
    func runDuplicationRepeatsRun() throws {
        let fixture = try runFixture()
        var prng = Xoshiro256(seed: 5)
        var lengthened = 0
        for _ in 0 ..< 30 {
            guard let child = FuzzMutator.duplicateElementRun(fixture.sequence, targets: fixture.targets, prng: &prng) else {
                continue
            }
            let parentValues = values(of: fixture.sequence)
            let childValues = values(of: child)
            #expect(childValues.count > parentValues.count)
            let added = childValues.count - parentValues.count
            // The child is the parent with one run repeated: removing one copy of some run of length `added` recovers the parent.
            var recovered = false
            for start in 0 ... (childValues.count - added) where childValues[start ..< start + added].elementsEqual(childValues[(start - added < 0 ? start + added : start - added) ..< (start - added < 0 ? start + 2 * added : start)]) {
                var candidate = childValues
                candidate.removeSubrange(start ..< start + added)
                if candidate == parentValues {
                    recovered = true
                    break
                }
            }
            #expect(recovered, "duplicated child is not the parent with one adjacent run repeated")
            #expect(markersBalanced(child))
            lengthened += 1
        }
        #expect(lengthened > 0)
    }

    @Test("Run copy keeps the element count and writes the source run over the target run")
    func runCopyOverwritesDisjointRun() throws {
        let fixture = try runFixture()
        var prng = Xoshiro256(seed: 11)
        var copied = 0
        for _ in 0 ..< 40 {
            guard let child = FuzzMutator.copyElementRun(fixture.sequence, targets: fixture.targets, prng: &prng) else {
                continue
            }
            let parentValues = values(of: fixture.sequence)
            let childValues = values(of: child)
            #expect(childValues.count == parentValues.count)
            #expect(Set(childValues).isSubset(of: Set(parentValues)), "copy introduced a value the parent did not have")
            #expect(markersBalanced(child))
            if childValues != parentValues {
                copied += 1
            }
        }
        #expect(copied > 0)
    }

    @Test("Run copy never misses on a node with two or more elements")
    func runCopyNeverMisses() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1_000_000), within: 2 ... 3, scaling: .constant)
        let (sequence, tree) = try materializedParent(gen, minimumValues: 2)
        let targets = MutationTargets(tree: tree)
        var prng = Xoshiro256(seed: 13)
        for _ in 0 ..< 50 {
            let child = FuzzMutator.copyElementRun(sequence, targets: targets, prng: &prng)
            #expect(child != nil, "run copy missed on a node of \(values(of: sequence).count) elements")
        }
    }

    @Test("Suffix reseed shortens the sequence node and reseeds only the sites after it")
    func suffixReseedCutsAndReseedsTail() throws {
        let gen = arrayThenLeafGenerator()
        let (parentSequence, parentTree) = try materializedParent(gen, minimumValues: 5)
        let targets = MutationTargets(tree: parentTree)
        #expect(targets.structuralArms.contains(.suffixReseed))
        var prng = Xoshiro256(seed: 7)
        var tailReseeded = 0
        for seed in UInt64(1) ... 30 {
            guard let cut = FuzzMutator.suffixReseed(parentSequence, targets: targets, prng: &prng) else {
                continue
            }
            #expect(cut.candidate.count < parentSequence.count)
            #expect(cut.reseedRanges.count == 1, "exactly the trailing leaf should be reseeded, got \(cut.reseedRanges)")
            let trailing = try #require(cut.reseedRanges.first)
            // The trailing leaf is the last value entry; the zip's close marker follows it.
            let lastValueIndex = try #require(cut.candidate.lastIndex { if case .value = $0 { return true } else { return false } })
            #expect(trailing == lastValueIndex ... lastValueIndex)
            guard case let .success(_, child, _) = Materializer.materializeAnyFlat(
                gen.erase(),
                context: .init(
                    prefix: cut.candidate,
                    mode: .guided(seed: seed, fallbackTree: parentTree),
                    reseedRanges: cut.reseedRanges
                )
            ) else {
                Issue.record("shortened candidate did not materialise")
                continue
            }
            #expect(values(of: child).dropLast().elementsEqual(values(of: cut.candidate).dropLast()), "array elements before the cut moved")
            if values(of: child).last != values(of: parentSequence).last {
                tailReseeded += 1
            }
        }
        #expect(tailReseeded > 0, "thirty suffix reseeds never redrew the trailing leaf")
    }
}

// MARK: - Helpers

private struct RunFixture {
    let sequence: ChoiceSequence
    let targets: MutationTargets
}

/// A single sequence node with room to shrink and grow: a length range of 1 to 16 at constant scaling, since the interpreter's first run is at size 1, and a parent seed chosen so the node holds at least six elements.
private func runFixture() throws -> RunFixture {
    let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1_000_000), within: 1 ... 16, scaling: .constant)
    let (sequence, tree) = try materializedParent(gen, minimumValues: 6)
    let targets = MutationTargets(tree: tree)
    #expect(targets.structuralArms.contains(.runDeletion))
    #expect(targets.structuralArms.contains(.runDuplication))
    #expect(targets.structuralArms.contains(.runCopy))
    return RunFixture(sequence: sequence, targets: targets)
}

private func arrayThenLeafGenerator() -> Generator<([UInt64], UInt64)> {
    let array: Generator<[UInt64]> = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 12, scaling: .constant)
    let trailing: Generator<UInt64> = Gen.choose(in: UInt64(500_000) ... 1_000_000)
    return Gen.zip(array, trailing)
}

/// Draws parents from successive seeds until one carries at least `minimumValues` value entries, so the fixture always has runs to work with.
private func materializedParent(_ gen: Generator<some Any>, minimumValues: Int) throws -> (ChoiceSequence, ChoiceTree) {
    for seed in UInt64(1) ... 200 {
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)
        if values(of: sequence).count >= minimumValues {
            return (sequence, tree)
        }
    }
    throw RunFixtureError.noParentLongEnough
}

private enum RunFixtureError: Error {
    case noParentLongEnough
}

private func values(of sequence: ChoiceSequence) -> [UInt64] {
    sequence.compactMap { entry in
        if case let .value(value) = entry { return value.choice.bitPattern64 }
        return nil
    }
}

private func isSubsequence(_ candidate: [UInt64], of parent: [UInt64]) -> Bool {
    var index = 0
    for value in parent where index < candidate.count && candidate[index] == value {
        index += 1
    }
    return index == candidate.count
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

/// Draws a parent at exactly the given seed, for properties that quantify over the seed rather than scanning for a fixture.
private func materializedParent(_ gen: Generator<some Any>, seed: UInt64) throws -> (ChoiceSequence, ChoiceTree) {
    var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 1)
    let (_, tree) = try #require(try interpreter.next())
    return (ChoiceSequence.flatten(tree), tree)
}

/// Counts how many seed pairs reached a deletion, so a property that never mutated cannot read as a pass.
private final class DeletionCounter {
    private(set) var total = 0

    func increment() {
        total += 1
    }
}
