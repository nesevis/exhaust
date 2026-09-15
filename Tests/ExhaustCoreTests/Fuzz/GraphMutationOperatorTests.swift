import Testing
@testable import ExhaustCore

@Suite("Graph mutation operators")
struct GraphMutationOperatorTests {
    // MARK: - Swap

    @Test("Swap exchanges two sibling spans and preserves the value multiset")
    func swapExchangesSpans() throws {
        let fixture = try #require(zipFixture())
        var prng = Xoshiro256(seed: 7)
        let swapped = try #require(FuzzMutator.swapSiblingSpans(
            fixture.sequence,
            targets: fixture.targets,
            prng: &prng
        ))
        #expect(swapped.count == fixture.sequence.count)
        #expect(swapped != fixture.sequence)
        #expect(valueMultiset(of: swapped) == valueMultiset(of: fixture.sequence))
    }

    // MARK: - Shuffle

    @Test("Shuffle permutes a sibling group and preserves the value multiset")
    func shufflePermutesGroup() throws {
        let fixture = try #require(zipFixture())
        var prng = Xoshiro256(seed: 3)
        var produced = 0
        for _ in 0 ..< 20 {
            guard let shuffled = FuzzMutator.shuffleSiblingSpans(
                fixture.sequence,
                targets: fixture.targets,
                prng: &prng
            ) else {
                // The identity permutation is a declared cheap miss.
                continue
            }
            produced += 1
            #expect(shuffled.count == fixture.sequence.count)
            #expect(shuffled != fixture.sequence)
            #expect(valueMultiset(of: shuffled) == valueMultiset(of: fixture.sequence))
        }
        #expect(produced > 0, "Every draw over 20 rounds was the identity permutation")
    }

    // MARK: - Move

    @Test("Move repositions one span and preserves the value multiset")
    func moveRepositionsSpan() throws {
        let fixture = try #require(zipFixture())
        var prng = Xoshiro256(seed: 11)
        let moved = try #require(FuzzMutator.moveSiblingSpan(
            fixture.sequence,
            targets: fixture.targets,
            prng: &prng
        ))
        #expect(moved.count == fixture.sequence.count)
        #expect(moved != fixture.sequence)
        #expect(valueMultiset(of: moved) == valueMultiset(of: fixture.sequence))
    }

    // MARK: - Lockstep Delta

    @Test("Lockstep delta shifts every changed group member by one shared delta")
    func lockstepSharedDelta() throws {
        let fixture = try #require(zipFixture())
        var prng = Xoshiro256(seed: 5)
        let shifted = try #require(FuzzMutator.lockstepDelta(
            fixture.sequence,
            targets: fixture.targets,
            prng: &prng
        ))
        #expect(shifted.count == fixture.sequence.count)

        var deltas: Set<Int64> = []
        var changed = 0
        for index in fixture.sequence.indices {
            guard case let .value(original) = fixture.sequence[index],
                  case let .value(mutated) = shifted[index]
            else {
                #expect(shifted[index] == fixture.sequence[index])
                continue
            }
            if mutated.choice.bitPattern64 != original.choice.bitPattern64 {
                changed += 1
                let delta = Int64(bitPattern: mutated.choice.bitPattern64 &- original.choice.bitPattern64)
                deltas.insert(delta)
            }
        }
        #expect(changed >= 2)
        #expect(deltas.count == 1, "Group members moved by differing deltas: \(deltas)")
    }

    @Test("Lockstep keeps small floating-point differences across wide domains", arguments: [TypeTag.float16, .float, .double])
    func lockstepPreservesFloatingDifferences(tag: TypeTag) throws {
        let tree = try ChoiceTree.group([1.0, 2.0].map { value in
            try ChoiceTree.choice(
                #require(tag.floatingChoice(from: value)),
                .init(validRange: nil, isRangeExplicit: false)
            )
        })
        let sequence = ChoiceSequence.flatten(tree)
        let targets = MutationTargets(tree: tree)
        var prng = Xoshiro256(seed: 5)
        for _ in 0 ..< 200 {
            let shifted = try #require(FuzzMutator.lockstepDelta(sequence, targets: targets, prng: &prng))
            let values = shifted.compactMap { $0.value?.choice.decodedDoubleValue }
            #expect(values.count == 2)
            #expect(values[1] - values[0] == 1.0)
        }
    }

    @Test("Floating lockstep mutations match the reducer's candidates", arguments: [TypeTag.float16, .float, .double])
    func lockstepMatchesReducerFloatingCandidates(tag: TypeTag) throws {
        let tree = try ChoiceTree.group([100.0, 101.0].map { value in
            try ChoiceTree.choice(
                #require(tag.floatingChoice(from: value)),
                .init(validRange: nil, isRangeExplicit: false)
            )
        })
        let sequence = ChoiceSequence.flatten(tree)
        let indices = sequence.indices.filter { sequence[$0].value != nil }
        let targets = MutationTargets(tree: tree)
        var reducer = GraphLockstepEncoder()
        reducer.valueState.reset(sequence: sequence)
        let plan = try #require(reducer.makeLockstepWindowPlan(windowIndices: indices))
        var prng = Xoshiro256(seed: 5)
        var compared = 0
        for _ in 0 ..< 200 {
            guard let shifted = FuzzMutator.lockstepDelta(sequence, targets: targets, prng: &prng),
                  let first = shifted[indices[0]].value?.choice.decodedDoubleValue,
                  first >= 0, first < 100
            else { continue }
            let delta = UInt64(100 - first)
            #expect(reducer.makeLockstepCandidate(plan: plan, delta: delta) == shifted)
            compared += 1
        }
        #expect(compared > 0)
    }

    @Test("Lockstep draws within the group's remaining headroom")
    func lockstepFitsNarrowHeadroom() throws {
        let tree = ChoiceTree.group([
            boundedLeaf(0, in: 0 ... 2),
            boundedLeaf(1, in: 0 ... 2),
        ])
        let sequence = ChoiceSequence.flatten(tree)
        let targets = MutationTargets(tree: tree)
        var prng = Xoshiro256(seed: 5)
        for _ in 0 ..< 40 {
            let shifted = try #require(FuzzMutator.lockstepDelta(sequence, targets: targets, prng: &prng))
            #expect(shifted.compactMap { $0.value?.choice.bitPattern64 } == [1, 2])
        }
    }

    @Test("Lockstep misses rather than shifting part of a group when one member is boundary-pinned")
    func lockstepRefusesPartialGroup() throws {
        // Three same-tag leaves, one pinned to a single-value range so no nonzero delta keeps it inside.
        let tree = ChoiceTree.group([
            boundedLeaf(500, in: 0 ... 1000),
            boundedLeaf(600, in: 0 ... 1000),
            boundedLeaf(7, in: 7 ... 7),
        ])
        let targets = MutationTargets(tree: tree)
        let sequence = ChoiceSequence.flatten(tree)
        try #require(targets.tandem != nil)

        var prng = Xoshiro256(seed: 19)
        for _ in 0 ..< 200 {
            guard let shifted = FuzzMutator.lockstepDelta(sequence, targets: targets, prng: &prng) else {
                continue
            }
            Issue.record("Shifted a group whose pinned member cannot move: \(shifted)")
            return
        }
    }

    @Test("Lockstep shifts every member by one delta when all can move")
    func lockstepShiftsWholeGroup() throws {
        let tree = ChoiceTree.group([
            boundedLeaf(500, in: 0 ... 1000),
            boundedLeaf(600, in: 0 ... 1000),
            boundedLeaf(700, in: 0 ... 1000),
        ])
        let targets = MutationTargets(tree: tree)
        let sequence = ChoiceSequence.flatten(tree)

        var prng = Xoshiro256(seed: 23)
        var shifted: ChoiceSequence?
        for _ in 0 ..< 200 where shifted == nil {
            shifted = FuzzMutator.lockstepDelta(sequence, targets: targets, prng: &prng)
        }
        let moved = try #require(shifted, "No draw over 200 rounds produced a shift")

        var deltas: Set<UInt64> = []
        for index in sequence.indices {
            guard case let .value(original) = sequence[index],
                  case let .value(mutated) = moved[index]
            else {
                continue
            }
            deltas.insert(mutated.choice.bitPattern64 &- original.choice.bitPattern64)
        }
        #expect(deltas.count == 1, "Members moved by differing deltas: \(deltas)")
        #expect(deltas.contains(0) == false, "A member did not move")
    }

    // MARK: - Determinism

    @Test("Every operator is deterministic under a pinned seed")
    func determinism() throws {
        let fixture = try #require(zipFixture())
        for seed in [1, 9, 42] as [UInt64] {
            var firstPRNG = Xoshiro256(seed: seed)
            var secondPRNG = Xoshiro256(seed: seed)
            #expect(
                FuzzMutator.swapSiblingSpans(fixture.sequence, targets: fixture.targets, prng: &firstPRNG)
                    == FuzzMutator.swapSiblingSpans(fixture.sequence, targets: fixture.targets, prng: &secondPRNG)
            )
            #expect(
                FuzzMutator.shuffleSiblingSpans(fixture.sequence, targets: fixture.targets, prng: &firstPRNG)
                    == FuzzMutator.shuffleSiblingSpans(fixture.sequence, targets: fixture.targets, prng: &secondPRNG)
            )
            #expect(
                FuzzMutator.moveSiblingSpan(fixture.sequence, targets: fixture.targets, prng: &firstPRNG)
                    == FuzzMutator.moveSiblingSpan(fixture.sequence, targets: fixture.targets, prng: &secondPRNG)
            )
            #expect(
                FuzzMutator.lockstepDelta(fixture.sequence, targets: fixture.targets, prng: &firstPRNG)
                    == FuzzMutator.lockstepDelta(fixture.sequence, targets: fixture.targets, prng: &secondPRNG)
            )
            #expect(firstPRNG.currentState == secondPRNG.currentState)
        }
    }

    // MARK: - Drift Bounds

    @Test("Operators miss cheaply when positions exceed a drifted candidate")
    func driftedCandidateMisses() throws {
        let fixture = try #require(zipFixture())
        // A candidate truncated below every group position: the span operators must return nil rather than trap.
        let truncated = ChoiceSequence(fixture.sequence.prefix(1))
        var prng = Xoshiro256(seed: 2)
        #expect(FuzzMutator.swapSiblingSpans(truncated, targets: fixture.targets, prng: &prng) == nil)
        #expect(FuzzMutator.shuffleSiblingSpans(truncated, targets: fixture.targets, prng: &prng) == nil)
        #expect(FuzzMutator.moveSiblingSpan(truncated, targets: fixture.targets, prng: &prng) == nil)
        #expect(FuzzMutator.lockstepDelta(truncated, targets: fixture.targets, prng: &prng) == nil)
    }

    // MARK: - Materialization

    @Test("Operator candidates from a real generator materialize under guidance", arguments: [7, 99, 1234] as [UInt64])
    func operatorCandidatesMaterialize(seed: UInt64) throws {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 1_000_000 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 1_000_000 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 1_000_000 as ClosedRange<Int>)
        )
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed, maxRuns: 1)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)
        let targets = MutationTargets(tree: tree)

        var prng = Xoshiro256(seed: seed)
        var candidates: [ChoiceSequence] = []
        if let swapped = FuzzMutator.swapSiblingSpans(sequence, targets: targets, prng: &prng) {
            candidates.append(swapped)
        }
        if let shifted = FuzzMutator.lockstepDelta(sequence, targets: targets, prng: &prng) {
            candidates.append(shifted)
        }
        #expect(candidates.isEmpty == false)

        let erased = gen.erase()
        for candidate in candidates {
            let result = Materializer.materializeAny(
                erased,
                prefix: candidate,
                mode: .guided(seed: seed, fallbackTree: tree)
            )
            guard case .success = result else {
                Issue.record("Operator candidate was not absorbed by guided materialization, seed \(seed)")
                continue
            }
        }
    }

    // MARK: - Target Construction

    @Test("Targeting tables are built on the first parent draw, not at admission")
    func targetsBuildOnFirstDraw() throws {
        let fixture = try #require(zipFixture())
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: true, pair: false))
        let index = try admitMutable(fixture, into: corpus)

        #expect(corpus.entries[index].mutationTargets == nil, "Admission built the tables eagerly")
        let targets = try #require(corpus.mutationTargets(forParentAt: index))
        #expect(targets.tandem != nil)
        #expect(targets.permutationScopes.isEmpty == false)
        #expect(targets.twinSpanGroups.isEmpty == false)
        #expect(corpus.entries[index].mutationTargets != nil, "The first draw did not cache its build")
    }

    @Test("A run whose knobs consume no targeting tables never builds one")
    func targetsSkippedWhenKnobsOff() throws {
        let fixture = try #require(zipFixture())
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: false, pair: false))
        let index = try admitMutable(fixture, into: corpus)

        #expect(corpus.mutationTargets(forParentAt: index) == nil)
        #expect(corpus.entries[index].mutationTargets == nil)
    }

    @Test("The crossover donor pool forces an eager build, since other entries read it")
    func pairMutationBuildsEagerly() throws {
        let fixture = try #require(zipFixture())
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: false, pair: true))
        let index = try admitMutable(fixture, into: corpus)

        #expect(corpus.entries[index].mutationTargets != nil)
    }

    @Test("A discovery-tier entry never builds targeting tables")
    func discoveryTierBuildsNoTargets() throws {
        let fixture = try #require(zipFixture())
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: true, pair: true))
        let admission = corpus.offer(
            sequence: fixture.sequence,
            tree: fixture.tree,
            hits: [(edge: 0, hitCount: 1)],
            convergence: 0.1,
            generation: 0,
            phase: .mutation
        )
        guard case let .admitted(index, tier) = admission else {
            Issue.record("Discovery-tier candidate was not admitted")
            return
        }
        #expect(tier == .discovery)
        #expect(corpus.mutationTargets(forParentAt: index) == nil)
        #expect(corpus.entries[index].mutationTargets == nil)
    }

    // MARK: - Twin Splice

    @Test("Twin detection groups the zip's same-site siblings")
    func twinDetection() throws {
        let fixture = try #require(zipFixture())
        let groups = fixture.targets.twinSpanGroups
        #expect(groups.count == 1)
        #expect(groups[0].count == 3)
        #expect(groups[0] == groups[0].sorted { $0.lowerBound < $1.lowerBound })
    }

    @Test("Twin splice copies one twin span over a sibling, creating agreement")
    func twinSpliceCreatesAgreement() throws {
        let fixture = try #require(zipFixture())
        var prng = Xoshiro256(seed: 13)
        let spliced = try #require(FuzzMutator.twinSplice(
            fixture.sequence,
            targets: fixture.targets,
            prng: &prng
        ))
        #expect(spliced != fixture.sequence)
        // The fixture's three twins carry distinct values; a splice duplicates one of them.
        let originalDistinct = Set(valueMultiset(of: fixture.sequence)).count
        let splicedDistinct = Set(valueMultiset(of: spliced)).count
        #expect(splicedDistinct == originalDistinct - 1)
    }

    // MARK: - Typed Crossover

    @Test("Typed crossover grafts a same-fingerprint span from a different entry")
    func typedCrossoverGraftsDonorSpan() throws {
        let corpus = FuzzCorpus(edgeCount: 4)
        let recipientIndex = try admitPickPair(
            into: corpus,
            fingerprint: 7,
            values: (111, 222),
            edge: 0
        )
        _ = try admitPickPair(into: corpus, fingerprint: 7, values: (333, 444), edge: 1)

        let recipient = corpus.entries[recipientIndex]
        let recipientTargets = try #require(recipient.mutationTargets)
        var prng = Xoshiro256(seed: 3)
        var grafted = 0
        for _ in 0 ..< 20 {
            guard let crossed = FuzzMutator.typedCrossover(
                recipient.sequence,
                parentHash: recipient.hash,
                targets: recipientTargets,
                corpus: corpus,
                prng: &prng
            ) else {
                // A draw that lands on the recipient's own donor rows is a declared cheap miss.
                continue
            }
            grafted += 1
            #expect(crossed != recipient.sequence)
            let donorValues: Set<UInt64> = [333, 444]
            #expect(valueMultiset(of: crossed).contains { donorValues.contains($0) })
        }
        #expect(grafted > 0, "Every draw over 20 rounds hit the recipient's own donor rows")
    }

    @Test("Typed crossover never donates from the recipient's own entry")
    func typedCrossoverExcludesSelf() throws {
        let corpus = FuzzCorpus(edgeCount: 4)
        let recipientIndex = try admitPickPair(
            into: corpus,
            fingerprint: 7,
            values: (111, 222),
            edge: 0
        )
        let recipient = corpus.entries[recipientIndex]
        let recipientTargets = try #require(recipient.mutationTargets)
        var prng = Xoshiro256(seed: 3)
        for _ in 0 ..< 20 {
            #expect(FuzzMutator.typedCrossover(
                recipient.sequence,
                parentHash: recipient.hash,
                targets: recipientTargets,
                corpus: corpus,
                prng: &prng
            ) == nil)
        }
    }

    @Test("Quarantine removes an entry's donor rows")
    func quarantineRemovesDonorRows() throws {
        let corpus = FuzzCorpus(edgeCount: 4)
        let recipientIndex = try admitPickPair(
            into: corpus,
            fingerprint: 7,
            values: (111, 222),
            edge: 0
        )
        let donorIndex = try admitPickPair(into: corpus, fingerprint: 7, values: (333, 444), edge: 1)
        corpus.quarantine(sequenceHash: corpus.entries[donorIndex].hash)

        let recipient = corpus.entries[recipientIndex]
        let recipientTargets = try #require(recipient.mutationTargets)
        var prng = Xoshiro256(seed: 3)
        for _ in 0 ..< 20 {
            #expect(FuzzMutator.typedCrossover(
                recipient.sequence,
                parentHash: recipient.hash,
                targets: recipientTargets,
                corpus: corpus,
                prng: &prng
            ) == nil)
        }
    }

    @Test("Twin splice and typed crossover are deterministic under a pinned seed")
    func pairOperatorDeterminism() throws {
        let fixture = try #require(zipFixture())
        let corpus = FuzzCorpus(edgeCount: 4)
        let recipientIndex = try admitPickPair(
            into: corpus,
            fingerprint: 7,
            values: (111, 222),
            edge: 0
        )
        _ = try admitPickPair(into: corpus, fingerprint: 7, values: (333, 444), edge: 1)
        let recipient = corpus.entries[recipientIndex]
        let recipientTargets = try #require(recipient.mutationTargets)

        for seed in [1, 9, 42] as [UInt64] {
            var firstPRNG = Xoshiro256(seed: seed)
            var secondPRNG = Xoshiro256(seed: seed)
            #expect(
                FuzzMutator.twinSplice(fixture.sequence, targets: fixture.targets, prng: &firstPRNG)
                    == FuzzMutator.twinSplice(fixture.sequence, targets: fixture.targets, prng: &secondPRNG)
            )
            #expect(
                FuzzMutator.typedCrossover(recipient.sequence, parentHash: recipient.hash, targets: recipientTargets, corpus: corpus, prng: &firstPRNG)
                    == FuzzMutator.typedCrossover(recipient.sequence, parentHash: recipient.hash, targets: recipientTargets, corpus: corpus, prng: &secondPRNG)
            )
            #expect(firstPRNG.currentState == secondPRNG.currentState)
        }
    }

    // MARK: - Bandit Inventory

    @Test("A band-only bandit never picks a graph arm and ignores its rewards")
    func banditInventoryRestriction() {
        var bandOnly = MutationBandit()
        for step in 0 ..< 1000 {
            let arm = bandOnly.pick(random: Double(step) / 1000)
            #expect(MutationArm.bandArms.contains(arm))
        }
        let before = bandOnly.probabilities
        bandOnly.reward(.swap, drawProbability: bandOnly.probability(of: .swap))
        bandOnly.reward(.lockstepDelta, drawProbability: bandOnly.probability(of: .lockstepDelta))
        #expect(bandOnly.probabilities == before)

        var full = MutationBandit(arms: MutationArm.allCases)
        var sawGraphArm = false
        for step in 0 ..< 1000 {
            let arm = full.pick(random: Double(step) / 1000)
            if MutationArm.bandArms.contains(arm) == false {
                sawGraphArm = true
            }
        }
        #expect(sawGraphArm)
        full.reward(.swap, drawProbability: full.probability(of: .swap))
        #expect(full.probabilities[MutationArm.swap.rawValue] > full.probabilities[MutationArm.shuffle.rawValue])
    }
}

// MARK: - Helpers

/// A `uint64` leaf with an explicit valid range.
private func boundedLeaf(_ value: UInt64, in range: ClosedRange<UInt64>) -> ChoiceTree {
    .choice(
        ChoiceValue(value, tag: .uint64),
        .init(validRange: range, isRangeExplicit: true)
    )
}

/// Experiment knobs with only the two targeting consumers under test set, so a change to the shipped defaults cannot alter what these tests assert.
private func targetingExperiments(graph: Bool, pair: Bool) -> FuzzExperiments {
    var experiments = FuzzExperiments()
    experiments.graphMutation = graph
    experiments.pairMutation = pair
    return experiments
}

/// Admits the fixture at mutable-tier convergence, returning its corpus index.
private func admitMutable(_ fixture: ZipFixture, into corpus: FuzzCorpus) throws -> Int {
    let admission = corpus.offer(
        sequence: fixture.sequence,
        tree: fixture.tree,
        hits: [(edge: 0, hitCount: 1)],
        convergence: 1.0,
        generation: 0,
        phase: .mutation
    )
    guard case let .admitted(index, tier) = admission, tier == .mutable else {
        throw MutationOperatorTestError.admissionFailed
    }
    return index
}

/// A zip of three single-element sequences of distinct `uint64` leaves: one swappable group of three same-shaped siblings, one tandem group over the leaves.
private struct ZipFixture {
    let tree: ChoiceTree
    let sequence: ChoiceSequence
    let targets: MutationTargets
}

private func zipFixture() -> ZipFixture? {
    let leafValues: [UInt64] = [10000, 20000, 30000]
    let children = leafValues.map { value in
        ChoiceTree.sequence(
            elements: [
                .choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 1_000_000, isRangeExplicit: true)),
            ],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
    }
    let tree = ChoiceTree.group(children)
    let targets = MutationTargets(tree: tree)
    guard targets.permutationScopes.isEmpty == false else {
        return nil
    }
    return ZipFixture(
        tree: tree,
        sequence: ChoiceSequence.flatten(tree),
        targets: targets
    )
}

/// Admits a mutable-tier entry whose tree holds two same-fingerprint pick sites with the given selected values, returning its corpus index.
private func admitPickPair(
    into corpus: FuzzCorpus,
    fingerprint: UInt64,
    values: (UInt64, UInt64),
    edge: Int
) throws -> Int {
    let tree = ChoiceTree.group([
        pickSite(fingerprint: fingerprint, selectedValue: values.0),
        pickSite(fingerprint: fingerprint, selectedValue: values.1),
    ])
    let admission = corpus.offer(
        sequence: ChoiceSequence.flatten(tree),
        tree: tree,
        hits: [(edge: edge, hitCount: 1)],
        convergence: 1.0,
        generation: 0,
        phase: .mutation
    )
    guard case let .admitted(index, tier) = admission, tier == .mutable else {
        throw MutationOperatorTestError.admissionFailed
    }
    return index
}

/// A two-branch pick site with the second branch selected, carrying the given leaf value.
private func pickSite(fingerprint: UInt64, selectedValue: UInt64) -> ChoiceTree {
    .group([
        .branch(
            fingerprint: fingerprint, weight: 1, id: 0, branchCount: 2,
            choice: .choice(ChoiceValue(0 as UInt64, tag: .uint64), .init(validRange: 0 ... 1_000_000))
        ),
        .branch(
            fingerprint: fingerprint, weight: 1, id: 1, branchCount: 2,
            choice: .choice(ChoiceValue(selectedValue, tag: .uint64), .init(validRange: 0 ... 1_000_000)),
            isSelected: true
        ),
    ])
}

private enum MutationOperatorTestError: Error {
    case admissionFailed
}

/// The sorted bit patterns of every `.value` entry, for permutation-invariance assertions.
private func valueMultiset(of sequence: ChoiceSequence) -> [UInt64] {
    var patterns: [UInt64] = []
    for element in sequence {
        if case let .value(entry) = element {
            patterns.append(entry.choice.bitPattern64)
        }
    }
    return patterns.sorted()
}

// MARK: - Headroom Tests

@Suite("Value headroom")
struct ValueHeadroomTests {
    @Test("Unsigned integer at the middle of a range has headroom in both directions")
    func unsignedMiddle() {
        let current = UInt(50).bitPattern64
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(current, tag: .uint),
            validRange: UInt(10).bitPattern64 ... UInt(90).bitPattern64,
            isRangeExplicit: true
        )
        #expect(value.headroom(upward: true, tag: .uint) == 40)
        #expect(value.headroom(upward: false, tag: .uint) == 40)
    }

    @Test("Unsigned integer at the upper bound has zero upward headroom")
    func unsignedAtUpperBound() {
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(UInt(90).bitPattern64, tag: .uint),
            validRange: UInt(10).bitPattern64 ... UInt(90).bitPattern64,
            isRangeExplicit: true
        )
        #expect(value.headroom(upward: true, tag: .uint) == 0)
        #expect(value.headroom(upward: false, tag: .uint) == 80)
    }

    @Test("Unsigned integer at the lower bound has zero downward headroom")
    func unsignedAtLowerBound() {
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(UInt(10).bitPattern64, tag: .uint),
            validRange: UInt(10).bitPattern64 ... UInt(90).bitPattern64,
            isRangeExplicit: true
        )
        #expect(value.headroom(upward: true, tag: .uint) == 80)
        #expect(value.headroom(upward: false, tag: .uint) == 0)
    }

    @Test("Signed integer headroom respects the XOR encoding")
    func signedHeadroom() {
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(Int(3).bitPattern64, tag: .int),
            validRange: Int(-7).bitPattern64 ... Int(7).bitPattern64,
            isRangeExplicit: true
        )
        #expect(value.headroom(upward: true, tag: .int) == 4)
        #expect(value.headroom(upward: false, tag: .int) == 10)
    }

    @Test("Non-explicit range yields max headroom for the bit pattern")
    func nonExplicitRange() {
        let current = UInt(50).bitPattern64
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(current, tag: .uint),
            validRange: UInt(10).bitPattern64 ... UInt(90).bitPattern64,
            isRangeExplicit: false
        )
        #expect(value.headroom(upward: true, tag: .uint) == UInt64.max - current)
        #expect(value.headroom(upward: false, tag: .uint) == current)
    }

    @Test("Nil range yields max headroom for the bit pattern")
    func nilRange() {
        let current = UInt(50).bitPattern64
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(current, tag: .uint),
            validRange: nil,
            isRangeExplicit: false
        )
        #expect(value.headroom(upward: true, tag: .uint) == UInt64.max - current)
        #expect(value.headroom(upward: false, tag: .uint) == current)
    }

    @Test("Float16 without explicit range bounds headroom by finite magnitude")
    func float16NonExplicitRange() {
        let encoded = Float16Emulation.encodedBitPattern(from: 100.0)
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(encoded, tag: .float16),
            validRange: nil,
            isRangeExplicit: false
        )
        let upward = value.headroom(upward: true, tag: .float16)
        let downward = value.headroom(upward: false, tag: .float16)
        #expect(upward <= 65504)
        #expect(downward <= 65504 + 100)
        #expect(upward > 0)
        #expect(downward > 0)
    }

    @Test("Double without explicit range saturates to max because finite magnitude exceeds UInt64")
    func doubleNonExplicitRangeSaturates() {
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(Double(1000.0).bitPattern64, tag: .double),
            validRange: nil,
            isRangeExplicit: false
        )
        #expect(value.headroom(upward: true, tag: .double) == .max)
        #expect(value.headroom(upward: false, tag: .double) == .max)
    }

    @Test("Float16 near finite max has small upward headroom")
    func float16NearMax() {
        let encoded = Float16Emulation.encodedBitPattern(from: 65000.0)
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(encoded, tag: .float16),
            validRange: nil,
            isRangeExplicit: false
        )
        let upward = value.headroom(upward: true, tag: .float16)
        #expect(upward <= 512)
        #expect(upward > 0)
    }

    @Test("Float with explicit range computes headroom from bounds")
    func floatExplicitRange() {
        let lower = Float(-10.0).bitPattern64
        let upper = Float(10.0).bitPattern64
        let current = Float(3.0).bitPattern64
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(current, tag: .float),
            validRange: lower ... upper,
            isRangeExplicit: true
        )
        #expect(value.headroom(upward: true, tag: .float) == 7)
        #expect(value.headroom(upward: false, tag: .float) == 13)
    }
}

// MARK: - Sequence Length Bound Tests

@Suite("Sequence length bounds in mutation targets")
struct SequenceLengthBoundTests {
    @Test("Deletion excludes a sequence at its lower bound")
    func deletionRespectsLowerBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 2 ... 5, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.deletableSequenceNodeIDs.isEmpty)
    }

    @Test("Deletion includes a sequence above its lower bound")
    func deletionAllowsAboveLowerBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 2 ... 5, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.deletableSequenceNodeIDs.isEmpty == false)
    }

    @Test("Duplication excludes a sequence at its upper bound")
    func duplicationRespectsUpperBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 1 ... 3, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.duplicableSequenceNodeIDs.isEmpty)
    }

    @Test("Duplication includes a sequence below its upper bound")
    func duplicationAllowsBelowUpperBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 1 ... 5, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.duplicableSequenceNodeIDs.isEmpty == false)
    }

    @Test("Fixed-length sequence excludes both deletion and duplication")
    func fixedLengthExcludesBoth() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 2 ... 2, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.deletableSequenceNodeIDs.isEmpty)
        #expect(targets.duplicableSequenceNodeIDs.isEmpty)
    }
}

// MARK: - Crossover Self-Donation Tests

@Suite("Crossover excludes self-donation")
struct CrossoverSelfDonationTests {
    @Test("Single-entry corpus reports no crossover donor")
    func singleEntryHasNoCrossoverDonor() throws {
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: true, pair: true))
        let parentIndex = try admitPickPair(into: corpus, fingerprint: 42, values: (100, 200), edge: 0)
        let targets = corpus.mutationTargets(forParentAt: parentIndex)!
        #expect(targets.hasCrossoverDonor(corpus: corpus, parentIndex: parentIndex) == false)
    }

    @Test("Two-entry corpus with matching fingerprints reports a crossover donor")
    func twoEntriesHaveCrossoverDonor() throws {
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: true, pair: true))
        let firstIndex = try admitPickPair(into: corpus, fingerprint: 42, values: (100, 200), edge: 0)
        _ = try admitPickPair(into: corpus, fingerprint: 42, values: (300, 400), edge: 1)
        let targets = corpus.mutationTargets(forParentAt: firstIndex)!
        #expect(targets.hasCrossoverDonor(corpus: corpus, parentIndex: firstIndex))
    }
}

// MARK: - Query Reuse Parity Tests

@Suite("Shape-key and deletable-set parity after query unification")
struct QueryReuseParityTests {
    @Test("NodeShapeKey distinguishes every node kind and groups same-shaped siblings")
    func shapeKeyCoversAllKinds() {
        let leaf1 = ChoiceTree.choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let leaf2 = ChoiceTree.choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let leaf3 = ChoiceTree.choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let tree = ChoiceTree.group([leaf1, leaf2, leaf3])
        let graph = ChoiceGraphBuilder.build(from: tree)

        var keys: [PermutationQuery.NodeShapeKey] = []
        for nodeID in graph.liveNodeIDs {
            keys.append(PermutationQuery.nodeShapeKey(graph.nodes[nodeID]))
        }
        let valueKeys = keys.filter { $0 == .value }
        #expect(valueKeys.count == 3)

        let scopes = PermutationQuery.build(graph: graph)
        #expect(scopes.count == 1)
        #expect(scopes[0].swappableGroups[0].count == 3)
    }

    @Test("NodeShapeKey separates sequences by element count and isolates empty sequences")
    func shapeKeySeparatesSequences() {
        let seq1 = ChoiceTree.sequence(
            elements: [boundedLeaf(1, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            elements: [boundedLeaf(2, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let seq3 = ChoiceTree.sequence(
            elements: [boundedLeaf(3, in: 0 ... 100), boundedLeaf(4, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2, seq3])
        let graph = ChoiceGraphBuilder.build(from: tree)

        let scopes = PermutationQuery.build(graph: graph)
        #expect(scopes.count == 1)
        #expect(scopes[0].swappableGroups.count == 1)
        #expect(scopes[0].swappableGroups[0].count == 2)
    }

    @Test("Deletable set from RemovalQuery matches the length-constraint rule on a multi-sequence tree")
    func deletableSetMatchesRule() {
        let deletable = ChoiceTree.sequence(
            elements: [boundedLeaf(1, in: 0 ... 100), boundedLeaf(2, in: 0 ... 100), boundedLeaf(3, in: 0 ... 100)],
            metadata: .init(validRange: 1 ... 5, isRangeExplicit: true)
        )
        let atBound = ChoiceTree.sequence(
            elements: [boundedLeaf(4, in: 0 ... 100), boundedLeaf(5, in: 0 ... 100)],
            metadata: .init(validRange: 2 ... 5, isRangeExplicit: true)
        )
        let unconstrained = ChoiceTree.sequence(
            elements: [boundedLeaf(6, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([deletable, atBound, unconstrained])
        let targets = MutationTargets(tree: tree)

        #expect(targets.deletableSequenceNodeIDs.count == 2)

        let graph = targets.graph
        for nodeID in targets.deletableSequenceNodeIDs {
            guard case let .sequence(metadata) = graph.nodes[nodeID].kind else {
                Issue.record("Deletable node \(nodeID) is not a sequence")
                continue
            }
            let lower = metadata.lengthConstraint?.lowerBound ?? 0
            #expect(UInt64(metadata.elementCount) > lower)
        }

        let removalScopes = RemovalQuery.elementRemovalScopes(graph: graph)
        let scopeNodeIDs = removalScopes.compactMap { $0.targets.first?.sequenceNodeID }
        #expect(targets.deletableSequenceNodeIDs == scopeNodeIDs)
    }

    @Test("Repertoire sights a superset of the per-parent structural arms")
    func repertoireIsSuperset() {
        let leaf1 = boundedLeaf(100, in: 0 ... 200)
        let leaf2 = boundedLeaf(150, in: 0 ... 200)
        let leaf3 = boundedLeaf(175, in: 0 ... 200)
        let zipBranch = ChoiceTree.group([leaf1, leaf2, leaf3])
        let scalarBranch = boundedLeaf(0, in: 0 ... 0)
        let tree = ChoiceTree.group([
            .branch(fingerprint: 1, weight: 1, id: 0, branchCount: 2, choice: scalarBranch, isSelected: true),
            .branch(fingerprint: 1, weight: 1, id: 1, branchCount: 2, choice: zipBranch),
        ])
        let fullGraph = ChoiceGraphBuilder.build(from: tree)
        let sighted = MutationArmRepertoire.sighted(in: fullGraph)

        let targets = MutationTargets(tree: tree)
        for arm in MutationArm.allCases where targets.structuralArms.contains(arm) {
            #expect(sighted.contains(arm), "Repertoire missing arm \(arm) that targets reports")
        }
    }

    @Test("Seeded fuzz run produces deterministic arm counts across two identical runs")
    func seededRunDeterminism() {
        func run() -> FuzzRunCounts {
            var experiments = FuzzExperiments()
            experiments.graphMutation = true
            experiments.pairMutation = true
            let runner = FuzzRunner(
                gen: Gen.zip(
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
                ),
                property: { value in
                    value.0 + value.1 + value.2 > 2800 ? .fail(.returnedFalse) : .pass
                },
                source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 32, edges: { value in
                    [value.0 & 0b111, 8 + (value.1 & 0b111), 16 + (value.2 & 0b111)]
                }),
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: 1337,
                    attemptLimit: 5000,
                    experiments: experiments
                )
            )
            return runner.run().counts
        }
        let first = run()
        let second = run()
        for arm in MutationArm.allCases {
            #expect(first.mutationArms.draws(arm: arm) == second.mutationArms.draws(arm: arm))
            #expect(first.mutationArms.misses(arm: arm) == second.mutationArms.misses(arm: arm))
            #expect(first.mutationArms.admissions(arm: arm) == second.mutationArms.admissions(arm: arm))
        }
        #expect(first.totalAttempts == second.totalAttempts)
    }
}
