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
            scopes: fixture.permutationScopes,
            graph: fixture.graph,
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
                scopes: fixture.permutationScopes,
                graph: fixture.graph,
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
            scopes: fixture.permutationScopes,
            graph: fixture.graph,
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
        let tandem = try #require(fixture.tandemScope)
        let shifted = try #require(FuzzMutator.lockstepDelta(
            fixture.sequence,
            tandem: tandem,
            graph: fixture.graph,
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
        let tandem = try #require(fixture.tandemScope)
        for seed in [1, 9, 42] as [UInt64] {
            var firstPRNG = Xoshiro256(seed: seed)
            var secondPRNG = Xoshiro256(seed: seed)
            #expect(
                FuzzMutator.swapSiblingSpans(fixture.sequence, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &firstPRNG)
                    == FuzzMutator.swapSiblingSpans(fixture.sequence, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &secondPRNG)
            )
            #expect(
                FuzzMutator.shuffleSiblingSpans(fixture.sequence, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &firstPRNG)
                    == FuzzMutator.shuffleSiblingSpans(fixture.sequence, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &secondPRNG)
            )
            #expect(
                FuzzMutator.moveSiblingSpan(fixture.sequence, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &firstPRNG)
                    == FuzzMutator.moveSiblingSpan(fixture.sequence, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &secondPRNG)
            )
            #expect(
                FuzzMutator.lockstepDelta(fixture.sequence, tandem: tandem, graph: fixture.graph, prng: &firstPRNG)
                    == FuzzMutator.lockstepDelta(fixture.sequence, tandem: tandem, graph: fixture.graph, prng: &secondPRNG)
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
        #expect(FuzzMutator.swapSiblingSpans(truncated, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &prng) == nil)
        #expect(FuzzMutator.shuffleSiblingSpans(truncated, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &prng) == nil)
        #expect(FuzzMutator.moveSiblingSpan(truncated, scopes: fixture.permutationScopes, graph: fixture.graph, prng: &prng) == nil)
        let tandem = try #require(fixture.tandemScope)
        #expect(FuzzMutator.lockstepDelta(truncated, tandem: tandem, graph: fixture.graph, prng: &prng) == nil)
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
        let graph = ChoiceGraph.build(from: tree)
        let permutationScopes = PermutationQuery.build(graph: graph)
        let tandemScope = tandemScope(fromGraph: graph)

        var prng = Xoshiro256(seed: seed)
        var candidates: [ChoiceSequence] = []
        if let swapped = FuzzMutator.swapSiblingSpans(sequence, scopes: permutationScopes, graph: graph, prng: &prng) {
            candidates.append(swapped)
        }
        if let tandem = tandemScope,
           let shifted = FuzzMutator.lockstepDelta(sequence, tandem: tandem, graph: graph, prng: &prng)
        {
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

    // MARK: - Admission Caching

    @Test("Mutable-tier admission caches the graph and scopes; discovery tier does not")
    func admissionCachesScopes() throws {
        let fixture = try #require(zipFixture())
        let corpus = FuzzCorpus(edgeCount: 4)

        let mutableAdmission = corpus.offer(
            sequence: fixture.sequence,
            tree: fixture.tree,
            hits: [(edge: 0, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .mutation
        )
        guard case let .admitted(index, tier) = mutableAdmission else {
            Issue.record("Mutable-tier candidate was not admitted")
            return
        }
        #expect(tier == .mutable)
        let entry = corpus.entries[index]
        #expect(entry.choiceGraph != nil)
        #expect(entry.tandemScope != nil)
        #expect(entry.permutationScopes.isEmpty == false)

        var discoverySequence = fixture.sequence
        let firstValueIndex = try #require(discoverySequence.firstIndex { element in
            if case .value = element {
                return true
            }
            return false
        })
        guard case let .value(first) = discoverySequence[firstValueIndex] else {
            return
        }
        discoverySequence[firstValueIndex] = .value(.init(
            choice: ChoiceValue(first.choice.bitPattern64 ^ 1, tag: first.choice.tag),
            validRange: first.validRange,
            isRangeExplicit: first.isRangeExplicit
        ))
        let discoveryAdmission = corpus.offer(
            sequence: discoverySequence,
            tree: fixture.tree,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 0.1,
            generation: 0,
            phase: .mutation
        )
        guard case let .admitted(discoveryIndex, discoveryTier) = discoveryAdmission else {
            Issue.record("Discovery-tier candidate was not admitted")
            return
        }
        #expect(discoveryTier == .discovery)
        let discoveryEntry = corpus.entries[discoveryIndex]
        #expect(discoveryEntry.choiceGraph == nil)
        #expect(discoveryEntry.tandemScope == nil)
        #expect(discoveryEntry.permutationScopes.isEmpty)
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

/// A zip of three single-element sequences of distinct `uint64` leaves: one swappable group of three same-shaped siblings, one tandem group over the leaves.
private struct ZipFixture {
    let tree: ChoiceTree
    let sequence: ChoiceSequence
    let graph: ChoiceGraph
    let permutationScopes: [PermutationScope]
    let tandemScope: TandemScope?
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
    let graph = ChoiceGraph.build(from: tree)
    let permutationScopes = PermutationQuery.build(graph: graph)
    guard permutationScopes.isEmpty == false else {
        return nil
    }
    return ZipFixture(
        tree: tree,
        sequence: ChoiceSequence.flatten(tree),
        graph: graph,
        permutationScopes: permutationScopes,
        tandemScope: tandemScope(fromGraph: graph)
    )
}

/// Extracts the tandem scope from ``ExchangeQuery``'s scope list, or nil when the graph has none.
private func tandemScope(fromGraph graph: ChoiceGraph) -> TandemScope? {
    for scope in ExchangeQuery.build(graph: graph) {
        if case let .tandem(tandem) = scope {
            return tandem
        }
    }
    return nil
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
