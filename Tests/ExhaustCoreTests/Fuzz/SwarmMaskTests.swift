import ExhaustCore
import Testing

@Suite("Swarm mask tests")
struct SwarmMaskTests {
    @Test("Per-site masks are deterministic and independent of query order")
    func maskDeterminism() {
        let mask = SwarmMask.forIndex(3, rootSeed: 42)
        let forward = (1 ... 50).map { mask.allowedBranches(fingerprint: UInt64($0), branchCount: 4) }
        let backward = (1 ... 50).reversed().map { mask.allowedBranches(fingerprint: UInt64($0), branchCount: 4) }
        #expect(forward == Array(backward.reversed()))

        let again = SwarmMask.forIndex(3, rootSeed: 42)
        #expect(forward == (1 ... 50).map { again.allowedBranches(fingerprint: UInt64($0), branchCount: 4) })
    }

    @Test("Different epochs produce different masks and some sites stay uniform")
    func epochDiversity() {
        let sites = (1 ... 200).map(UInt64.init)
        let epochMasks = (0 ..< 4).map { epoch in
            sites.map { SwarmMask.forIndex(epoch, rootSeed: 7).allowedBranches(fingerprint: $0, branchCount: 4) }
        }
        #expect(Set(epochMasks.map { "\($0)" }).count == 4, "each epoch should draw a distinct mask")
        for masks in epochMasks {
            let unmaskedShare = Double(masks.count(where: { $0 == nil })) / Double(masks.count)
            #expect(unmaskedShare > 0.3 && unmaskedShare < 0.8, "roughly half of all sites stay uniform per epoch")
        }
    }

    @Test("A masked site always keeps at least one branch, and every kept branch is in range")
    func atLeastOneBranchSurvives() {
        for epoch in 0 ..< 8 {
            let mask = SwarmMask.forIndex(epoch, rootSeed: 99)
            for fingerprint in 1 ... 100 {
                guard let allowed = mask.allowedBranches(fingerprint: UInt64(fingerprint), branchCount: 4) else {
                    continue
                }
                #expect(allowed.isEmpty == false)
                #expect(allowed.count < 4, "a full allowance must report as unmasked nil")
                #expect(allowed.allSatisfy { $0 < 4 })
            }
        }
    }

    @Test("Unfingerprinted and single-branch sites are never masked")
    func unmaskableSites() {
        let mask = SwarmMask.forIndex(1, rootSeed: 5)
        #expect(mask.allowedBranches(fingerprint: 0, branchCount: 4) == nil)
        #expect(mask.allowedBranches(fingerprint: 17, branchCount: 1) == nil)
    }

    @Test("Applying the mask pivots only disallowed selections")
    func applyPivotsDisallowedBranches() {
        // Find a masked site so the test exercises a real pivot.
        let mask = SwarmMask.forIndex(0, rootSeed: 1)
        var maskedFingerprint: UInt64?
        for fingerprint in 1 ... 200 where mask.allowedBranches(fingerprint: UInt64(fingerprint), branchCount: 4) != nil {
            maskedFingerprint = UInt64(fingerprint)
            break
        }
        guard let fingerprint = maskedFingerprint,
              let allowed = mask.allowedBranches(fingerprint: fingerprint, branchCount: 4)
        else {
            Issue.record("no masked site among 200 fingerprints — the masking probability is broken")
            return
        }
        let disallowed = (0 ..< 4).first { allowed.contains(UInt64($0)) == false }.map(UInt64.init)!
        let sequence: ChoiceSequence = [
            .branch(.init(id: disallowed, branchCount: 4, fingerprint: fingerprint)),
            .branch(.init(id: allowed[0], branchCount: 4, fingerprint: fingerprint)),
            .just,
        ]
        var prng = Xoshiro256(seed: 11)
        let rewritten = mask.apply(to: sequence, prng: &prng)
        guard case let .branch(pivoted) = rewritten[0], case let .branch(untouched) = rewritten[1] else {
            Issue.record("branch entries lost in rewrite")
            return
        }
        #expect(allowed.contains(pivoted.id))
        #expect(untouched.id == allowed[0])
        #expect(rewritten[2] == .just)
    }
}

@Suite("Activated swarm mask tests")
struct ActivatedSwarmMaskTests {
    @Test("Weights are deterministic and independent of query order")
    func weightsDeterminism() {
        let mask = SwarmMask.forIndex(3, rootSeed: 42)
        let forward = (1 ... 50).map { mask.branchWeights(fingerprint: UInt64($0), branchCount: 4) }
        let backward = (1 ... 50).reversed().map { mask.branchWeights(fingerprint: UInt64($0), branchCount: 4) }
        #expect(forward == Array(backward.reversed()))

        let again = SwarmMask.forIndex(3, rootSeed: 42)
        #expect(forward == (1 ... 50).map { again.branchWeights(fingerprint: UInt64($0), branchCount: 4) })
    }

    @Test("Every masked site is weighted, and each weight is in [0, 1)")
    func weightsShapeAndRange() {
        let mask = SwarmMask.forIndex(1, rootSeed: 5)
        // Unfingerprinted and single-branch sites stay unweighted, as they stay unmasked.
        #expect(mask.branchWeights(fingerprint: 0, branchCount: 4) == nil)
        #expect(mask.branchWeights(fingerprint: 17, branchCount: 1) == nil)

        for fingerprint in 1 ... 100 {
            let weights = mask.branchWeights(fingerprint: UInt64(fingerprint), branchCount: 4)
            // Unlike the binary mask, no site stays uniform: a fingerprinted multi-branch site is always weighted.
            #expect(weights?.count == 4)
            #expect(weights?.allSatisfy { $0 >= 0 && $0 < 1 } == true)
        }
    }

    @Test("Applying activation preserves site identity and keeps every branch in range")
    func applyPreservesSiteAndRange() {
        let mask = SwarmMask.forIndex(2, rootSeed: 8)
        let sequence: ChoiceSequence = [
            .branch(.init(id: 0, branchCount: 4, fingerprint: 17)),
            .branch(.init(id: 2, branchCount: 3, fingerprint: 91)),
            .just,
        ]
        var prng = Xoshiro256(seed: 11)
        let rewritten = mask.applyActivated(to: sequence, prng: &prng)

        for (original, result) in zip(sequence, rewritten) {
            guard case let .branch(originalBranch) = original else {
                #expect(original == result, "non-branch entries are untouched")
                continue
            }
            guard case let .branch(resultBranch) = result else {
                Issue.record("a branch entry lost its kind in the rewrite")
                continue
            }
            #expect(resultBranch.fingerprint == originalBranch.fingerprint)
            #expect(resultBranch.branchCount == originalBranch.branchCount)
            #expect(resultBranch.id < originalBranch.branchCount)
        }
    }

    @Test("Applying activation is deterministic under a pinned seed")
    func applyDeterminism() {
        let mask = SwarmMask.forIndex(0, rootSeed: 1)
        let sequence = ChoiceSequence((0 ..< 20).map { index -> ChoiceSequenceValue in
            .branch(.init(id: UInt64(index % 4), branchCount: 4, fingerprint: UInt64(1 + index % 5)))
        })
        var first = Xoshiro256(seed: 7)
        var second = Xoshiro256(seed: 7)
        #expect(mask.applyActivated(to: sequence, prng: &first) == mask.applyActivated(to: sequence, prng: &second))
    }

    @Test("An out-of-range branch id is left untouched instead of trapping")
    func applyLeavesOutOfRangeIdUntouched() {
        let mask = SwarmMask.forIndex(2, rootSeed: 8)
        let branchCount: UInt64 = 4
        let fingerprint: UInt64 = 17
        // A fingerprinted multi-branch site is always weighted, so the activation path is reached and the guard, not a full allowance, is what spares the array access.
        #expect(mask.branchWeights(fingerprint: fingerprint, branchCount: branchCount) != nil)
        // id == branchCount is one past the last valid branch, the shape a resumed persistence document could carry unvalidated. The legacy path pivots such an id; the activation path must at least not trap.
        let sequence: ChoiceSequence = [
            .branch(.init(id: branchCount, branchCount: branchCount, fingerprint: fingerprint)),
        ]
        var prng = Xoshiro256(seed: 3)
        let rewritten = mask.applyActivated(to: sequence, prng: &prng)
        guard case let .branch(result) = rewritten[0] else {
            Issue.record("branch entry lost in rewrite")
            return
        }
        #expect(result.id == branchCount, "an out-of-range id is left untouched, not pivoted")
    }

    @Test("The realised branch mix converges to the normalised activation weights")
    func mixConvergesToWeights() throws {
        // The claim ADR 0006 rests on. Starting each branch from a uniform selection, one activation pass realizes branch j with probability w_j / Σw — the epoch weights, normalized. A low-activation branch is thinned out, a high-activation branch dominates, at the exact ratio the weights encode.
        let mask = SwarmMask.forIndex(0, rootSeed: 123)
        let branchCount: UInt64 = 4
        let fingerprint: UInt64 = 17
        let weights = try #require(mask.branchWeights(fingerprint: fingerprint, branchCount: branchCount))
        let total = weights.reduce(0, +)
        let expected = weights.map { $0 / total }

        var prng = Xoshiro256(seed: 20_260_821)
        var counts = [Int](repeating: 0, count: Int(branchCount))
        let trials = 40000
        for _ in 0 ..< trials {
            let start = prng.next(upperBound: branchCount)
            let sequence: ChoiceSequence = [.branch(.init(id: start, branchCount: branchCount, fingerprint: fingerprint))]
            guard case let .branch(result) = mask.applyActivated(to: sequence, prng: &prng)[0] else {
                Issue.record("branch entry lost in rewrite")
                continue
            }
            counts[Int(result.id)] += 1
        }

        for branch in 0 ..< Int(branchCount) {
            let observed = Double(counts[branch]) / Double(trials)
            #expect(abs(observed - expected[branch]) < 0.02, "branch \(branch): observed \(observed), expected \(expected[branch])")
        }
    }
}

@Suite("Flatten fingerprint preservation")
struct FlattenFingerprintTests {
    @Test("Branch entries keep their pick-site fingerprint through flattening")
    func flattenPreservesBranchFingerprint() throws {
        // Swarm masking keys per-site masks on the fingerprint; flatten dropping it silently disables masking for every pick site (found 2026-07-11 when the first swarm arm no-opped).
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 3 as ClosedRange<Int>).erase()),
            (1, Gen.choose(in: 10 ... 13 as ClosedRange<Int>).erase()),
        ])
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1, maxRuns: 3)
        let (_, tree) = try #require(try interpreter.next())
        let branches = ChoiceSequence.flatten(tree).compactMap { entry -> ChoiceSequenceValue.Branch? in
            guard case let .branch(branch) = entry else {
                return nil
            }
            return branch
        }
        #expect(branches.isEmpty == false)
        #expect(branches.allSatisfy { $0.fingerprint != 0 })
    }
}
