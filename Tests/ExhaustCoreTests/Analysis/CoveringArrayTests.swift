//
//  CoveringArrayTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Finite Domain Analysis

@Suite("Finite Domain Analysis")
struct FiniteDomainAnalysisTests {
    @Test("Bool generator produces 1 parameter with domain 2")
    func boolAnalysis() {
        let gen = Gen.choose(from: [true, false])
        let profile = analyzeFinite(gen)
        #expect(profile != nil)
        #expect(profile?.parameters.count == 1)
        #expect(profile?.parameters[0].domainSize == 2)
        #expect(profile?.totalSpace == 2)
    }

    @Test("Int range produces 1 parameter with correct domain")
    func intRangeAnalysis() {
        let gen = Gen.choose(in: 0 ... 4)
        let profile = analyzeFinite(gen)
        #expect(profile != nil)
        #expect(profile?.parameters.count == 1)
        #expect(profile?.parameters[0].domainSize == 5)
        #expect(profile?.totalSpace == 5)
    }

    @Test("Zip of finite generators produces correct parameter count")
    func zipAnalysis() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(in: 0 ... 2))
        let profile = analyzeFinite(gen)
        #expect(profile != nil)
        #expect(profile?.parameters.count == 3)
        #expect(profile?.parameters[0].domainSize == 2)
        #expect(profile?.parameters[1].domainSize == 2)
        #expect(profile?.parameters[2].domainSize == 3)
        #expect(profile?.totalSpace == 12)
    }

    @Test("Non-finite generator returns nil")
    func nonFiniteReturnsNil() {
        let gen = asciiStringGen(length: 1 ... 5)
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }

    @Test("Partially finite generator returns nil")
    func partiallyFiniteReturnsNil() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), asciiStringGen(length: 1 ... 5))
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }

    @Test("oneOf enum produces correct domain")
    func oneOfEnumAnalysis() {
        enum Direction: CaseIterable { case north, south, east, west }
        let gen = Gen.choose(from: Direction.allCases)
        let profile = analyzeFinite(gen)
        #expect(profile != nil)
        #expect(profile?.parameters.count == 1)
        #expect(profile?.parameters[0].domainSize == 4)
        #expect(profile?.totalSpace == 4)
    }

    @Test("Large domain range returns nil for finite")
    func largeDomainReturnsNilForFinite() {
        let gen = Gen.choose(in: 0 ... 1000)
        let profile = analyzeFinite(gen)
        #expect(profile == nil)
    }
}

// MARK: - IPOG Covering Array Generation

@Suite("IPOG Covering Array")
struct IPOGCoveringArrayTests {
    @Test("5 booleans at t=2 produces compact covering array")
    func fiveBoolsPairwise() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(from: [true, false]))
        let profile = analyzeFinite(gen)!
        let covering = CoveringArray.generate(profile: profile, strength: 2)!

        // Known bound: 5 booleans pairwise should need ~6 rows
        #expect(covering.rows.count <= 10)
        #expect(covering.rows.count >= 4)
        #expect(covering.strength == 2)

        // Verify pairwise coverage
        verifyTWayCoverage(covering: covering, profile: profile, strength: 2)
    }

    @Test("Coverage verification for mixed domains")
    func mixedDomainsCoverage() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(in: 0 ... 2), Gen.choose(in: 0 ... 3), Gen.choose(from: [true, false]))
        let profile = analyzeFinite(gen)!
        let covering = CoveringArray.generate(profile: profile, strength: 2)!

        verifyTWayCoverage(covering: covering, profile: profile, strength: 2)
    }

    @Test("Strength 3 produces valid covering array")
    func strength3() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(in: 0 ... 2))
        let profile = analyzeFinite(gen)!
        let covering = CoveringArray.generate(profile: profile, strength: 3)!

        verifyTWayCoverage(covering: covering, profile: profile, strength: 3)
    }

    @Test("Exhaustive enumeration when strength equals parameter count")
    func exhaustiveEnumeration() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(in: 0 ... 2))
        let profile = analyzeFinite(gen)!
        let covering = CoveringArray.generate(profile: profile, strength: profile.parameters.count)!

        // 2 * 2 * 3 = 12 rows
        #expect(covering.rows.count == 12)
    }

    @Test("bestFitting returns covering array within budget")
    func bestFitting() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(from: [true, false]))
        let profile = analyzeFinite(gen)!

        let covering = CoveringArray.bestFitting(budget: 10, profile: profile)
        #expect(covering != nil)
        #expect(covering!.strength >= 2)
        #expect(UInt64(covering!.rows.count) <= 10)
    }

    @Test("Large seed pair with many booleans — pairwise coverage holds")
    func largeSeedPairWithBooleans() {
        // Total space: 8 x 8 x 2^6 = 4096 combinations.
        // There are C(8,2) = 28 parameter pairs, with a total of
        // 8x8 + 8x2x6 + 8x2x6 + C(6,2)x2x2 = 64+96+96+60 = 316 pair-value tuples.
        // Random sampling at 100 runs hits each specific pair-value with
        // probability ~100/4096 ~ 2.4%, so many pairs would be missed entirely.
        // IPOG guarantees all 316 tuples in ~64-80 rows.
        //
        // The 8x8 seed = 64 rows dominates; horizontal growth must correctly
        // assign 6 boolean columns across those rows without missing any pair.
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 7),
            Gen.choose(in: 0 ... 7),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false])
        )
        let profile = analyzeFinite(gen)!
        let covering = CoveringArray.generate(profile: profile, strength: 2)!

        // 64-row seed should absorb most boolean pairs; expect modest growth
        #expect(covering.rows.count >= 64)
        #expect(covering.rows.count <= 80)

        verifyTWayCoverage(covering: covering, profile: profile, strength: 2)
    }

    @Test("Symmetric domains — tie-breaking covers all tuples")
    func symmetricDomains() {
        // Total space: 3^6 = 729 combinations.
        // There are C(6,2) = 15 parameter pairs, each with 3x3 = 9 value
        // combinations, for 135 pair-value tuples total.
        // Random sampling at 100 runs: each specific pair-value has probability
        // 100/9 ~ 11 expected hits — decent on average, but the birthday problem
        // means ~2-3 of the 135 tuples are likely missed per run.
        // IPOG guarantees all 135 tuples in ~15 rows.
        //
        // At t=3: C(6,3) = 20 triples, each with 3^3 = 27 value combinations,
        // for 540 triple-value tuples. Random at 100 runs hits each with
        // probability 100/729 ~ 14%, leaving ~460 triples uncovered.
        //
        // All domains are identical, so IPOG's greedy horizontal growth faces
        // maximum tie-breaking ambiguity — a stress test for bias bugs.
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2)
        )
        let profile = analyzeFinite(gen)!

        let pairwise = CoveringArray.generate(profile: profile, strength: 2)!
        verifyTWayCoverage(covering: pairwise, profile: profile, strength: 2)
        #expect(pairwise.rows.count <= 20)

        let threeway = CoveringArray.generate(profile: profile, strength: 3)!
        verifyTWayCoverage(covering: threeway, profile: profile, strength: 3)
    }
}

// MARK: - Replay

@Suite("Covering Array Replay")
struct CoveringArrayReplayTests {
    @Test("Replay of covering array row produces valid value")
    func replayProducesValidValue() throws {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]), Gen.choose(in: 0 ... 2))
        let profile = try #require(analyzeFinite(gen))
        let covering = try #require(CoveringArray.generate(profile: profile, strength: 2))

        var replayedCount = 0
        for row in covering.rows {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            let value: (Bool, Bool, Int)? = try Interpreters.replay(gen, using: tree)
            #expect(value != nil)
            if let value {
                // Verify the value matches the expected parameter values
                #expect(value.2 >= 0 && value.2 <= 2)
                replayedCount += 1
            }
        }
        #expect(replayedCount == covering.rows.count)
    }

    @Test("Replay of single bool parameter produces distinct values")
    func replaySingleBool() throws {
        let gen = Gen.choose(from: [true, false])
        let profile = try #require(analyzeFinite(gen))

        let row0 = CoveringArrayRow(values: [0])
        let tree0 = try #require(CoveringArrayReplay.buildTree(row: row0, profile: profile))
        let val0: Bool? = try Interpreters.replay(gen, using: tree0)
        #expect(val0 != nil)

        let row1 = CoveringArrayRow(values: [1])
        let tree1 = try #require(CoveringArrayReplay.buildTree(row: row1, profile: profile))
        let val1: Bool? = try Interpreters.replay(gen, using: tree1)
        #expect(val1 != nil)

        // The two value indices must produce distinct Bool values
        #expect(val0 != val1)
    }
}

// MARK: - Verification Helpers

private func verifyTWayCoverage(
    covering: CoveringArray,
    profile: FiniteDomainProfile,
    strength: Int,
) {
    let params = profile.parameters
    let n = params.count

    for combo in allCombinations(of: n, choose: strength) {
        var seen = Set<[UInt64]>()
        for row in covering.rows {
            let tuple = combo.map { row.values[$0] }
            seen.insert(tuple)
        }

        // Compute expected number of tuples for this combination
        var expected: UInt64 = 1
        for idx in combo {
            expected *= params[idx].domainSize
        }

        #expect(
            UInt64(seen.count) == expected,
            "Missing coverage for parameter combination \(combo): got \(seen.count), expected \(expected)"
        )
    }
}

private func analyzeFinite<Output>(_ gen: ReflectiveGenerator<Output>) -> FiniteDomainProfile? {
    guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else { return nil }
    return profile
}

private func allCombinations(of n: Int, choose k: Int) -> [[Int]] {
    guard k <= n, k > 0 else { return [] }
    var result: [[Int]] = []
    var current: [Int] = []
    current.reserveCapacity(k)

    func build(start: Int) {
        if current.count == k {
            result.append(current)
            return
        }
        let remaining = k - current.count
        for i in start ... (n - remaining) {
            current.append(i)
            build(start: i + 1)
            current.removeLast()
        }
    }

    build(start: 0)
    return result
}

private func asciiStringGen(length: ClosedRange<Int>) -> ReflectiveGenerator<String> {
    var rangeSet = RangeSet<UInt32>()
    rangeSet.insert(contentsOf: 0x0020 ..< 0x007F)
    let asciiSRS = ScalarRangeSet(rangeSet)
    let charGen = Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            return asciiSRS.index(of: scalar)
        },
        Gen.choose(in: 0 ... asciiSRS.scalarCount - 1)
            .map { Character(asciiSRS.scalar(at: $0)) }
    )
    return Gen.arrayOf(charGen, within: UInt64(length.lowerBound) ... UInt64(length.upperBound))
        .map { String($0) }
}
