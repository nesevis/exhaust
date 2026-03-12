//
//  CoveringArrayIntegrationTests.swift
//  Exhaust
//

import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Covering Array Integration")
struct CoveringArrayIntegrationTests {
    @Test("Bind-aware coverage: sibling parameters after bind are correctly replayed")
    func bindAwareSiblingAlignment() throws {
        // Gen.zip(bindGen, b, c) where bindGen has a bind.
        // Coverage analysis extracts only the inner parameter from the bind,
        // plus b and c — 3 finite parameters total.
        // PrefixMaterializer must replay b and c from the covering array,
        // not consume their prefix entries into the bind's bound subtree.
        let bindGen = #gen(.int(in: 0 ... 2)).bind { n in
            Gen.just(Array(repeating: n, count: n))
        }
        let gen = Gen.zip(bindGen, #gen(.int(in: 0 ... 3)), #gen(.int(in: 0 ... 3)))

        guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected finite analysis for zip(bind, int, int)")
            return
        }

        // inner(0...2), b(0...3), c(0...3) → 3 parameters
        #expect(profile.parameters.count == 3)
        #expect(profile.originalTree?.containsBind == true)

        let covering = try #require(
            CoveringArray.generate(profile: profile, strength: profile.parameters.count)
        )

        var replayedValues: [([Int], Int, Int)] = []
        for (rowIndex, row) in covering.rows.enumerated() {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            let prefix = ChoiceSequence(tree)
            guard let result = PrefixMaterializer.materialize(gen, prefix: prefix, seed: UInt64(rowIndex)) else {
                continue
            }
            // PrefixMaterializer.materialize returns the generator's Output type directly,
            // but Gen.zip erases to [Any] internally — cast to the concrete tuple.
            guard let value = result.value as? ([Int], Int, Int) else {
                Issue.record("Unexpected output type for row \(rowIndex)")
                continue
            }
            replayedValues.append(value)

            // b and c must match the covering array parameter values exactly
            let expectedB = Int(row.values[1])
            let expectedC = Int(row.values[2])
            #expect(value.1 == expectedB, "b should be \(expectedB) but got \(value.1) for row \(rowIndex)")
            #expect(value.2 == expectedC, "c should be \(expectedC) but got \(value.2) for row \(rowIndex)")
        }

        // Every row should replay successfully (no nils)
        #expect(replayedValues.count == covering.rows.count, "All \(covering.rows.count) rows should replay; got \(replayedValues.count)")

        // Verify that all distinct (b, c) pairs appear — full pairwise coverage
        let bcPairs = Set(replayedValues.map { "\($0.1),\($0.2)" })
        let expectedPairs = 4 * 4 // 0...3 × 0...3
        #expect(bcPairs.count == expectedPairs, "Expected all \(expectedPairs) (b,c) pairs; got \(bcPairs.count)")
    }

    @Test("Exhaustive mode covers full space for small generator")
    func exhaustiveCoversFullSpace() {
        // 2 * 2 * 3 = 12 total space, samplingBudget = 50 → exhaustive
        #exhaust(#gen(.bool(), .bool(), .int(in: 0 ... 2)), .samplingBudget(50)) { _, _, _ in
            true
        }
    }

    @Test("Property failure on finite generator is detected and shrunk")
    func propertyFailureDetected() {
        let gen = #gen(.bool(), .int(in: 0 ... 4))
        let result = #exhaust(gen, .samplingBudget(50), .suppressIssueReporting) { a, b in
            // Fails when a == true and b == 3
            !(a == true && b == 3)
        }
        #expect(result != nil)
    }

    @Test("randomOnly setting bypasses covering array")
    func randomOnlyBypass() {
        // With randomOnly, the covering array path is skipped
        // This should still work via random sampling
        let gen = #gen(.bool(), .bool())
        #exhaust(gen, .samplingBudget(50), .randomOnly) { _, _ in
            true
        }
    }

    @Test("3-way covering finds narrow failure that random misses")
    func threeWayNarrowFailure() {
        // Total space: 4^5 = 1024 combinations.
        // Failure condition: p0==2 AND p1==3 AND p3==1 — a specific 3-way
        // interaction. Only 4 of 1024 points satisfy it (p2 and p4 are free),
        // so P(hit per random sample) = 4/1024 = 1/256.
        // At 100 random samples: P(miss all) = (255/256)^100 ≈ 68%.
        //
        // A 3-way covering array for 5 params × 4 values needs ~100 rows and
        // is guaranteed to include every triple of parameter values, so it
        // always finds this failure — deterministically, not probabilistically.
        let gen = #gen(
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
        )

        let result = #exhaust(
            gen,
            .samplingBudget(100),
            .suppressIssueReporting,
        ) { p0, p1, _, p3, _ in
            !(p0 == 2 && p1 == 3 && p3 == 1)
        }
        #expect(result != nil, "3-way covering should always find this failure")
    }

    @Test("Comparison: random-only misses narrow 3-way failure at high rate")
    func randomOnlyMissesNarrowFailure() {
        // Same generator and property as above, but forced to random-only.
        // P(miss in a single 100-sample run) ≈ 68% (see above).
        // Over 20 trials, expected misses ≈ 13-14. We assert at least 1.
        let gen = #gen(
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
            .int(in: 0 ... 3),
        )

        var missCount = 0
        for _ in 0 ..< 40 {
            let result = #exhaust(
                gen,
                .samplingBudget(100),
                .randomOnly,
                .suppressIssueReporting,
            ) { p0, p1, _, p3, _ in
                !(p0 == 2 && p1 == 3 && p3 == 1)
            }
            if result == nil {
                missCount += 1
            }
        }
        // Random should miss at least once in 40 trials
        // (expected ~8 misses). If covering array were used, it would never miss.
        #expect(missCount >= 1, "Random-only should miss the narrow failure at least once in 20 trials")
    }
}
