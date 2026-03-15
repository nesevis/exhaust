//
//  CoveringArrayIntegrationTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("Covering Array Integration")
struct CoveringArrayIntegrationTests {
    @Test("Bind-aware coverage: sibling parameters after bind are correctly replayed")
    func bindAwareSiblingAlignment() throws {
        // Gen.zip(bindGen, b, c) where bindGen has a bind.
        // Coverage analysis extracts only the inner parameter from the bind,
        // plus b and c — 3 finite parameters total.
        // GuidedMaterializer must replay b and c from the covering array,
        // not consume their prefix entries into the bind's bound subtree.
        let bindGen: ReflectiveGenerator<[Int]> = Gen.liftF(.transform(
            kind: .bind(
                forward: { innerValue -> ReflectiveGenerator<Any> in
                    let n = innerValue as! Int
                    return Gen.just(Array(repeating: n, count: n)).erase()
                },
                backward: nil,
                inputType: "Int",
                outputType: "[Int]"
            ),
            inner: Gen.choose(in: 0 ... 2 as ClosedRange<Int>).erase()
        ))
        let gen = Gen.zip(bindGen, Gen.choose(in: 0 ... 3 as ClosedRange<Int>), Gen.choose(in: 0 ... 3 as ClosedRange<Int>))

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
            guard case let .success(resultValue, _, _) = GuidedMaterializer.materialize(gen, prefix: prefix, seed: UInt64(rowIndex)) else {
                continue
            }
            let value = resultValue
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
    func exhaustiveCoversFullSpace() throws {
        // 2 * 2 * 3 = 12 total space, samplingBudget = 50 → exhaustive
        let gen = Gen.zip(
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(in: 0 ... 2 as ClosedRange<Int>)
        )

        guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected finite analysis")
            return
        }

        let covering = try #require(
            CoveringArray.generate(profile: profile, strength: profile.parameters.count)
        )

        // Full exhaustive enumeration: 2 * 2 * 3 = 12 rows
        #expect(covering.rows.count == 12)

        // Replay every row and verify all pass
        var replayedCount = 0
        for row in covering.rows {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            let _: (Bool, Bool, Int)? = try Interpreters.replay(gen, using: tree)
            replayedCount += 1
        }
        #expect(replayedCount == 12)
    }

    @Test("Property failure on finite generator is detected via covering array")
    func propertyFailureDetected() throws {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(in: 0 ... 4 as ClosedRange<Int>))

        guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected finite analysis")
            return
        }

        let covering = try #require(
            CoveringArray.generate(profile: profile, strength: profile.parameters.count)
        )

        var foundFailure = false
        for row in covering.rows {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            guard let value: (Bool, Int) = try Interpreters.replay(gen, using: tree) else {
                continue
            }
            // Fails when a == true and b == 3
            if value.0 == true, value.1 == 3 {
                foundFailure = true
                break
            }
        }
        #expect(foundFailure)
    }

    @Test("randomOnly setting bypasses covering array — ValueInterpreter still works")
    func randomOnlyBypass() throws {
        // With randomOnly, the covering array path is skipped.
        // Verify that random sampling via ValueInterpreter still produces valid values.
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]))

        var iter = ValueInterpreter(gen, seed: 42, maxRuns: 50)
        var count = 0
        while let _ = try iter.next() {
            count += 1
        }
        #expect(count == 50)
    }

    @Test("3-way covering finds narrow failure that random misses")
    func threeWayNarrowFailure() throws {
        // Total space: 4^5 = 1024 combinations.
        // Failure condition: p0==2 AND p1==3 AND p3==1 — a specific 3-way
        // interaction. Only 4 of 1024 points satisfy it (p2 and p4 are free),
        // so P(hit per random sample) = 4/1024 = 1/256.
        //
        // A 3-way covering array for 5 params × 4 values needs ~100 rows and
        // is guaranteed to include every triple of parameter values, so it
        // always finds this failure — deterministically, not probabilistically.
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>)
        )

        guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected finite analysis")
            return
        }

        // Generate a 3-way covering array
        let covering = try #require(
            CoveringArray.generate(profile: profile, strength: 3)
        )

        var foundFailure = false
        for (rowIndex, row) in covering.rows.enumerated() {
            guard let tree = CoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            let prefix = ChoiceSequence(tree)
            guard case let .success(resultValue, _, _) = GuidedMaterializer.materialize(gen, prefix: prefix, seed: UInt64(rowIndex)) else {
                continue
            }
            let value = resultValue
            if value.0 == 2, value.1 == 3, value.3 == 1 {
                foundFailure = true
                break
            }
        }
        #expect(foundFailure, "3-way covering should always find this failure")
    }

    @Test("Comparison: random-only misses narrow 3-way failure at high rate")
    func randomOnlyMissesNarrowFailure() throws {
        // Same generator and property as above, but forced to random-only.
        // P(miss in a single 100-sample run) ≈ 68% (see above).
        // Over 40 trials, expected misses ≈ 27. We assert at least 1.
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 3 as ClosedRange<Int>)
        )

        var missCount = 0
        for trial in 0 ..< 40 {
            var iter = ValueInterpreter(gen, seed: UInt64(trial), maxRuns: 100)
            var foundInTrial = false
            while let value = try iter.next() {
                if value.0 == 2, value.1 == 3, value.3 == 1 {
                    foundInTrial = true
                    break
                }
            }
            if foundInTrial == false {
                missCount += 1
            }
        }
        // Random should miss at least once in 40 trials
        // (expected ~27 misses). If covering array were used, it would never miss.
        #expect(missCount >= 1, "Random-only should miss the narrow failure at least once in 40 trials")
    }
}
