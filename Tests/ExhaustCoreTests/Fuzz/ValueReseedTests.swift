import Testing
@testable import ExhaustCore

@Suite("Value reseed")
struct ValueReseedTests {
    @Test("Leaf reseeding resumes the prefix before a non-pure continuation", arguments: [false, true], [false, true])
    func leafReseedPreservesContinuation(inSequence: Bool, multipleTargets: Bool) throws {
        let leaf: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 1_000_000)
        let pair = leaf.bind { first in leaf.map { second in (first, second) } }
        let gen: Generator<[(UInt64, UInt64)]> = inSequence
            ? Gen.arrayOf(pair, exactly: 2)
            : Gen.zip(pair, pair).map { [$0.0, $0.1] }
        let (parentSequence, parentTree) = try materializedParent(gen)
        let sites = MutationTargets(tree: parentTree).reseedSites
        #expect(sites.count == 4)
        let first = try #require(sites.first)
        let third = try #require(sites.dropFirst(2).first)
        let ranges = multipleTargets ? [first.range, third.range] : [first.range]
        var changedRanges: Set<Int> = []

        for seed in UInt64(1) ... 20 {
            let child = try #require(flatChild(gen, prefix: parentSequence, tree: parentTree, seed: seed, reseeding: ranges))
            #expect(child.count == parentSequence.count)
            for index in child.indices where ranges.contains(where: { $0.contains(index) }) == false {
                #expect(child[index] == parentSequence[index], "entry \(index) outside the targeted leaves moved, seed \(seed)")
            }
            for (index, range) in ranges.enumerated() where child[range.lowerBound] != parentSequence[range.lowerBound] {
                changedRanges.insert(index)
            }
        }
        #expect(changedRanges.count == ranges.count, "every targeted leaf should be redrawn")
    }

    @Test("Reseeding one leaf redraws that entry and keeps every other entry")
    func leafReseedIsLocal() throws {
        let gen = leafZipGenerator()
        let (parentSequence, parentTree) = try materializedParent(gen)
        let targets = MutationTargets(tree: parentTree)
        let leafSites = targets.reseedSites.filter { site in
            if case .chooseBits = targets.graph.nodes[site.nodeID].kind { return true }
            return false
        }
        #expect(leafSites.count == 3)
        let site = try #require(leafSites.dropFirst().first)

        var changed = 0
        for seed in UInt64(1) ... 40 {
            let child = try #require(flatChild(gen, prefix: parentSequence, tree: parentTree, seed: seed, reseeding: [site.range]))
            #expect(child.count == parentSequence.count)
            for index in child.indices where site.range.contains(index) == false {
                #expect(child[index] == parentSequence[index], "entry \(index) outside the reseeded span moved, seed \(seed)")
            }
            if child[site.range.lowerBound] != parentSequence[site.range.lowerBound] {
                changed += 1
            }
        }
        #expect(changed > 0, "forty reseeds of a 0 ... 1_000_000 leaf never produced a different value")
    }

    @Test("Reseeding a pick redraws its branch and subtree and keeps the entries after it")
    func pickReseedRedrawsSubtree() throws {
        let gen = pickZipGenerator()
        let (parentSequence, parentTree) = try materializedParent(gen)
        let targets = MutationTargets(tree: parentTree)
        let pickSite = try #require(targets.reseedSites.first { site in
            if case .pick = targets.graph.nodes[site.nodeID].kind { return true }
            return false
        })
        let trailing = (pickSite.range.upperBound + 1) ..< parentSequence.count
        #expect(trailing.isEmpty == false)

        var branchChanged = 0
        for seed in UInt64(1) ... 40 {
            let child = try #require(flatChild(gen, prefix: parentSequence, tree: parentTree, seed: seed, reseeding: [pickSite.range]))
            // The trailing leaf keeps its parent value whatever the reseeded subtree's length turned out to be.
            #expect(child.last == parentSequence.last, "trailing entry moved, seed \(seed)")
            #expect(child.prefix(pickSite.range.lowerBound).elementsEqual(parentSequence.prefix(pickSite.range.lowerBound)))
            if selectedBranch(in: child, at: pickSite.range.lowerBound) != selectedBranch(in: parentSequence, at: pickSite.range.lowerBound) {
                branchChanged += 1
            }
        }
        #expect(branchChanged > 0, "forty reseeds of a two-arm pick never drew the other arm")
    }

    @Test("Reseed spans are disjoint and the all draw is the maximal antichain")
    func spansAreAnAntichain() throws {
        let gen = pickZipGenerator()
        let (parentSequence, parentTree) = try materializedParent(gen)
        let targets = MutationTargets(tree: parentTree)
        #expect(targets.structuralArms.contains(.valueReseed))
        for index in targets.maximalReseedSiteIndices {
            #expect(targets.reseedSites[index].containingSiteIndices.isEmpty)
        }

        var prng = Xoshiro256(seed: 5)
        for _ in 0 ..< 60 {
            guard let ranges = FuzzMutator.valueReseed(parentSequence, targets: targets, prng: &prng) else {
                continue
            }
            for (first, second) in zip(ranges, ranges.dropFirst()) {
                #expect(first.upperBound < second.lowerBound, "spans overlap or are unsorted: \(ranges)")
            }
            for range in ranges {
                #expect(range.upperBound < parentSequence.count)
            }
        }
    }

    @Test("Reseeding the first leaf of a zip redraws that leaf alone")
    func firstZipLeafReseedStaysLocal() throws {
        let gen = leafZipGenerator()
        let (parentSequence, parentTree) = try materializedParent(gen)
        let targets = MutationTargets(tree: parentTree)
        let site = try #require(targets.reseedSites.first)
        // The zip dispatches at the position just before its first leaf, and a start check that skips the zip marker matches there; the reseed must wait for the leaf itself or the whole zip is redrawn.
        for seed in UInt64(1) ... 20 {
            let child = try #require(flatChild(gen, prefix: parentSequence, tree: parentTree, seed: seed, reseeding: [site.range]))
            #expect(child.count == parentSequence.count)
            for index in child.indices where site.range.contains(index) == false {
                #expect(child[index] == parentSequence[index], "entry \(index) outside the first leaf moved, seed \(seed)")
            }
        }
    }

    @Test("Reseeding an element of an array redraws it, through the sequence handler's own element loop")
    func arrayElementReseedRedraws() throws {
        let leaf: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 1_000_000)
        let gen: Generator<[UInt64]> = Gen.arrayOf(leaf, exactly: 3)
        let (parentSequence, parentTree) = try materializedParent(gen)
        let targets = MutationTargets(tree: parentTree)
        let site = try #require(targets.reseedSites.dropFirst().first)
        var changed = 0
        for seed in UInt64(1) ... 40 {
            let child = try #require(flatChild(gen, prefix: parentSequence, tree: parentTree, seed: seed, reseeding: [site.range]))
            #expect(child.count == parentSequence.count)
            for index in child.indices where site.range.contains(index) == false {
                #expect(child[index] == parentSequence[index], "entry \(index) outside the element moved, seed \(seed)")
            }
            if child[site.range.lowerBound] != parentSequence[site.range.lowerBound] {
                changed += 1
            }
        }
        #expect(changed > 0, "forty reseeds of an array element never redrew it")
    }

    @Test("A leaf inside a bind inner is never a reseed site")
    func bindInnerLeavesAreExcluded() throws {
        let lengthGen: Generator<UInt64> = Gen.choose(in: UInt64(1) ... 4)
        let element: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 9)
        let gen: Generator<[UInt64]> = lengthGen._bound(
            forward: { (length: UInt64) -> AnyGenerator in Gen.arrayOf(element, exactly: length).erase() },
            backward: { (array: [UInt64]) -> UInt64 in UInt64(array.count) }
        )
        let (_, parentTree) = try materializedParent(gen)
        let targets = MutationTargets(tree: parentTree)
        for site in targets.reseedSites {
            #expect(targets.graph.nodes[site.nodeID].scopeAnnotation.isBindInner == false)
        }
    }
}

// MARK: - Helpers

private func leafZipGenerator() -> Generator<(UInt64, UInt64, UInt64)> {
    let leaf: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 1_000_000)
    return Gen.zip(leaf, leaf, leaf)
}

private func pickZipGenerator() -> Generator<(Any, UInt64)> {
    let scalarArm: Generator<Any> = Gen.choose(in: UInt64(0) ... 100).map { value -> Any in value }
    let pairArm: Generator<Any> = Gen.zip(
        Gen.choose(in: UInt64(0) ... 100),
        Gen.choose(in: UInt64(0) ... 100)
    ).map { pair -> Any in pair }
    let arm: Generator<Any> = Gen.pick(choices: [(1, scalarArm), (1, pairArm)])
    let trailing: Generator<UInt64> = Gen.choose(in: UInt64(500_000) ... 1_000_000)
    return Gen.zip(arm, trailing)
}

private func materializedParent(_ gen: Generator<some Any>) throws -> (ChoiceSequence, ChoiceTree) {
    var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: 99, maxRuns: 1)
    let (_, tree) = try #require(try interpreter.next())
    return (ChoiceSequence.flatten(tree), tree)
}

private func flatChild(
    _ gen: Generator<some Any>,
    prefix: ChoiceSequence,
    tree: ChoiceTree,
    seed: UInt64,
    reseeding ranges: [ClosedRange<Int>]
) -> ChoiceSequence? {
    guard case let .success(_, sequence, report) = Materializer.materializeAnyFlat(
        gen.erase(),
        prefix: prefix,
        mode: .guided(seed: seed, fallbackTree: tree),
        reseedRanges: ranges
    ) else {
        return nil
    }
    // A reseeded draw is a resolved coordinate: the child keeps full convergence and stays eligible for the mutable tier.
    #expect(report?.convergence == 1.0, "reseeded child lost convergence: \(report?.convergence ?? -1)")
    return sequence
}

private func selectedBranch(in sequence: ChoiceSequence, at start: Int) -> UInt64? {
    var index = start
    while index < sequence.count {
        if case let .branch(branch) = sequence[index] {
            return branch.id
        }
        index += 1
    }
    return nil
}
