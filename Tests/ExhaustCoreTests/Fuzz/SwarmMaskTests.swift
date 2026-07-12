import ExhaustCore
import Testing

@Suite("Swarm mask tests")
struct SwarmMaskTests {
    @Test("Per-site masks are deterministic and independent of query order")
    func maskDeterminism() {
        let mask = SwarmMask.forEpoch(index: 3, rootSeed: 42)
        let forward = (1 ... 50).map { mask.allowedBranches(fingerprint: UInt64($0), branchCount: 4) }
        let backward = (1 ... 50).reversed().map { mask.allowedBranches(fingerprint: UInt64($0), branchCount: 4) }
        #expect(forward == Array(backward.reversed()))

        let again = SwarmMask.forEpoch(index: 3, rootSeed: 42)
        #expect(forward == (1 ... 50).map { again.allowedBranches(fingerprint: UInt64($0), branchCount: 4) })
    }

    @Test("Different epochs produce different masks and some sites stay uniform")
    func epochDiversity() {
        let sites = (1 ... 200).map(UInt64.init)
        let epochMasks = (0 ..< 4).map { epoch in
            sites.map { SwarmMask.forEpoch(index: epoch, rootSeed: 7).allowedBranches(fingerprint: $0, branchCount: 4) }
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
            let mask = SwarmMask.forEpoch(index: epoch, rootSeed: 99)
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
        let mask = SwarmMask.forEpoch(index: 1, rootSeed: 5)
        #expect(mask.allowedBranches(fingerprint: 0, branchCount: 4) == nil)
        #expect(mask.allowedBranches(fingerprint: 17, branchCount: 1) == nil)
    }

    @Test("Applying the mask pivots only disallowed selections")
    func applyPivotsDisallowedBranches() {
        // Find a masked site so the test exercises a real pivot.
        let mask = SwarmMask.forEpoch(index: 0, rootSeed: 1)
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
