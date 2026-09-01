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

    // MARK: - Stall Gate

    @Test("The quiet-child counter increments per child and resets on admission")
    func quietChildCounter() throws {
        let fixture = try #require(zipFixture())
        let corpus = FuzzCorpus(edgeCount: 4)
        let admission = corpus.offer(
            sequence: fixture.sequence,
            tree: fixture.tree,
            hits: [(edge: 0, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .mutation
        )
        guard case let .admitted(index, _) = admission else {
            Issue.record("Fixture entry was not admitted")
            return
        }
        #expect(corpus.childrenSinceAdmission(forParentAt: index) == 0)
        for count in 1 ... 5 {
            corpus.noteChild(forParentAt: index, admitted: false)
            #expect(corpus.childrenSinceAdmission(forParentAt: index) == count)
        }
        corpus.noteChild(forParentAt: index, admitted: true)
        #expect(corpus.childrenSinceAdmission(forParentAt: index) == 0)
    }

    // MARK: - Bandit Inventory

    @Test("A legacy-sized bandit never picks a graph arm and ignores its rewards")
    func banditInventoryRestriction() {
        var legacy = MutationBandit()
        for step in 0 ..< 1000 {
            let arm = legacy.pick(random: Double(step) / 1000)
            #expect(arm.rawValue < MutationArm.legacyArmCount)
        }
        let before = legacy.probabilities
        legacy.reward(.swap)
        legacy.reward(.lockstepDelta)
        #expect(legacy.probabilities == before)

        var full = MutationBandit(armCount: MutationArm.allCases.count)
        var sawGraphArm = false
        for step in 0 ..< 1000 {
            let arm = full.pick(random: Double(step) / 1000)
            if arm.rawValue >= MutationArm.legacyArmCount {
                sawGraphArm = true
            }
        }
        #expect(sawGraphArm)
        full.reward(.swap)
        #expect(full.probabilities[MutationArm.swap.rawValue] > full.probabilities[MutationArm.shuffle.rawValue])
    }
}

// MARK: - Helpers

/// Experiment knobs with only the two targeting consumers under test set, so a change to the shipped defaults cannot alter what these tests assert.
private func targetingExperiments(graph: Bool, pair: Bool) -> FuzzExperiments {
    var experiments = FuzzExperiments()
    experiments.graphMutation = graph
    experiments.pairMutation = pair
    experiments.campaignMutation = false
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
