import ExhaustCore
import Testing

@Suite("Balanced Covering Array")
struct BalancedCoveringArrayTests {
    // MARK: - Greedy Path (domains ≤ greedyThreshold)

    @Test("5 booleans covers all pairs")
    func fiveBoolsPairwise() {
        let domains: [UInt64] = [2, 2, 2, 2, 2]
        let rows = generateAll(domainSizes: domains, budget: 1000)

        verifyTWayCoverage(rows: rows, domainSizes: domains)
    }

    @Test("Mixed small domains cover all pairs")
    func mixedSmallDomains() {
        let domains: [UInt64] = [2, 3, 4, 2]
        let rows = generateAll(domainSizes: domains, budget: 1000)

        verifyTWayCoverage(rows: rows, domainSizes: domains)
    }

    @Test("Greedy path terminates when fully covered")
    func greedyExhaustion() {
        let domains: [UInt64] = [2, 2, 2]
        let generator = BalancedCoveringArrayGenerator(domainSizes: domains)

        var count = 0
        while generator.next() != nil {
            count += 1
            if count > 100 { break }
        }

        #expect(generator.next() == nil)
    }

    @Test("Greedy determinism — same inputs produce identical rows")
    func greedyDeterminism() {
        let domains: [UInt64] = [3, 4, 2, 5]
        let rows1 = generateAll(domainSizes: domains, budget: 1000)
        let rows2 = generateAll(domainSizes: domains, budget: 1000)

        #expect(rows1.count == rows2.count)
        for index in 0 ..< rows1.count {
            #expect(rows1[index].values == rows2[index].values)
        }
    }

    @Test("Different covering seeds produce different row sequences")
    func differentSeedsRotateRows() {
        // The rotation itself: if the seed were ignored, every run would build the identical array and per-run rotation would be dead code that no other test notices.
        let domains: [UInt64] = [4, 4, 4]
        let rowsA = generateAll(domainSizes: domains, budget: 1000, seed: 1).map(\.values)
        let rowsB = generateAll(domainSizes: domains, budget: 1000, seed: 2).map(\.values)

        #expect(rowsA != rowsB)
    }

    @Test("A seeded greedy array still covers all pairs", arguments: [UInt64(1), 7, 12345])
    func seededGreedyCoversAllPairs(seed: UInt64) {
        // The rotation offset picks among equally optimal values, so termination-on-full-coverage must survive any seed.
        let domains: [UInt64] = [2, 3, 4, 2]
        let rows = generateAll(domainSizes: domains, budget: 1000, seed: seed)

        verifyTWayCoverage(rows: rows, domainSizes: domains)
    }

    // MARK: - Fast Path (domains > greedyThreshold)

    @Test("Different covering seeds produce different spread row sequences")
    func differentSeedsRotateSpreadRows() {
        // Domains above greedyThreshold take the spread path, whose lap offset must mix the seed like the greedy scan does: otherwise large-domain spaces would build the identical array every run and rotation would silently not apply to them.
        let domains: [UInt64] = [65, 4]
        let rowsA = generateAll(domainSizes: domains, budget: 200, seed: 1).map(\.values)
        let rowsB = generateAll(domainSizes: domains, budget: 200, seed: 2).map(\.values)

        #expect(rowsA != rowsB)
    }

    @Test("Fast path activates for domains above threshold")
    func fastPathActivation() {
        let largeDomain = UInt64(BalancedCoveringArrayGenerator.greedyThreshold + 1)
        let domains: [UInt64] = [largeDomain, largeDomain, largeDomain]
        let generator = BalancedCoveringArrayGenerator(domainSizes: domains)

        let row = generator.next()
        #expect(row != nil)

        let secondRow = generator.next()
        #expect(secondRow != nil)
        #expect(row!.values != secondRow!.values)
    }

    @Test("Fast path values are within bounds")
    func fastPathBounds() {
        let domains: [UInt64] = [100, 200, 150, 80, 120]
        let rows = generateAll(domainSizes: domains, budget: 500)

        for row in rows {
            #expect(row.values.count == domains.count)
            for param in 0 ..< domains.count {
                #expect(
                    row.values[param] < domains[param],
                    "Param \(param) (domain \(domains[param])) out of range: \(row.values[param])"
                )
            }
        }
    }

    @Test("Fast path determinism — same inputs produce identical rows")
    func fastPathDeterminism() {
        let domains: [UInt64] = [200, 200, 200, 200, 200]
        let rows1 = generateAll(domainSizes: domains, budget: 200)
        let rows2 = generateAll(domainSizes: domains, budget: 200)

        #expect(rows1.count == rows2.count)
        for index in 0 ..< rows1.count {
            #expect(rows1[index].values == rows2[index].values)
        }
    }

    @Test("Fast path produces distinct rows")
    func fastPathDistinctRows() {
        let domains: [UInt64] = [200, 200, 200, 200, 200]
        let rows = generateAll(domainSizes: domains, budget: 200)

        let unique = Set(rows.map(\.values))
        #expect(unique.count == rows.count, "Expected all rows to be distinct, got \(unique.count)/\(rows.count)")
    }

    @Test("Fast path value coverage — each parameter uses diverse values")
    func fastPathValueCoverage() {
        let domains: [UInt64] = [200, 200, 200, 200, 200]
        let budget = 200
        let rows = generateAll(domainSizes: domains, budget: budget)

        for param in 0 ..< domains.count {
            let distinct = Set(rows.map { $0.values[param] })
            let coverage = Double(distinct.count) / Double(domains[param])
            let percent = Int(coverage * 100)
            #expect(
                coverage >= 0.5,
                "Param \(param): only \(distinct.count)/\(domains[param]) values used (\(percent)% coverage)"
            )
        }
    }

    @Test("Fast path pairwise diversity — each parameter pair sees many distinct tuples")
    func fastPathPairwiseDiversity() {
        let domains: [UInt64] = [200, 200, 200, 200, 200]
        let budget = 200
        let rows = generateAll(domainSizes: domains, budget: budget)

        for paramA in 0 ..< domains.count {
            for paramB in (paramA + 1) ..< domains.count {
                let pairs = Set(rows.map { [$0.values[paramA], $0.values[paramB]] })
                let pairCount = pairs.count
                #expect(
                    pairCount == budget,
                    "Params (\(paramA), \(paramB)): only \(pairCount)/\(budget) distinct pairs"
                )
            }
        }
    }

    @Test("Fast path with mixed domains — asymmetric sizes")
    func fastPathMixedDomains() {
        let domains: [UInt64] = [100, 500, 73, 200, 150, 90, 300]
        let budget = 200
        let rows = generateAll(domainSizes: domains, budget: budget)

        #expect(rows.count == budget)

        for row in rows {
            for param in 0 ..< domains.count {
                #expect(row.values[param] < domains[param])
            }
        }

        let unique = Set(rows.map(\.values))
        #expect(unique.count == budget, "Expected all rows to be distinct")
    }

    @Test("Fast path with clamped domains — large inputs are capped")
    func fastPathClamping() {
        let domains: [UInt64] = [100_000, 100_000, 100_000]
        let perParamCap = UInt64(BalancedCoveringArrayGenerator.maxDomainSize / 3)

        let rows = generateAll(domainSizes: domains, budget: 100)
        for row in rows {
            for param in 0 ..< domains.count {
                #expect(
                    row.values[param] < perParamCap,
                    "Param \(param) exceeded clamped domain: \(row.values[param]) >= \(perParamCap)"
                )
            }
        }
    }

    @Test("Fast path never returns nil within budget")
    func fastPathNeverReturnsNil() {
        let domains: [UInt64] = [200, 200, 200]
        let generator = BalancedCoveringArrayGenerator(domainSizes: domains)

        for _ in 0 ..< 1000 {
            #expect(generator.next() != nil)
        }
    }

    @Test("Fast path covers all pairs for domains sharing a factor")
    func fastPathSharedFactorPairCoverage() {
        // Without the per-lap phase offset, stride cycling repeats pairs with period lcm(132, 6) = 132, capping coverage at 132 of the 792 pairs at any budget.
        let domains: [UInt64] = [132, 6]
        let rows = generateAll(domainSizes: domains, budget: 20000)

        let pairs = Set(rows.map { [$0.values[0], $0.values[1]] })
        #expect(
            pairs.count == 132 * 6,
            "Expected full pairwise coverage, got \(pairs.count)/\(132 * 6)"
        )
    }

    @Test("Fast path covers all pairs for equal-sized domains")
    func fastPathEqualDomainsPairCoverage() {
        // Equal domains are the worst case for the joint period: lcm(15, 15) = 15, so without the per-lap phase offset the 15x15 slice never exceeds 15 of its 225 pairs. The 70 domain exists only to activate spread mode.
        let domains: [UInt64] = [70, 15, 15]
        let rows = generateAll(domainSizes: domains, budget: 20000)

        let pairs = Set(rows.map { [$0.values[1], $0.values[2]] })
        #expect(
            pairs.count == 15 * 15,
            "Expected full pairwise coverage of the equal-domain slice, got \(pairs.count)/\(15 * 15)"
        )
    }

    // MARK: - Seed Rotation

    @Test("Consecutive seeds do not share spread rows")
    func consecutiveSeedsDoNotShareSpreadRows() {
        // Folding the lap into the base seed made seed s + 1 draw seed s's offset one lap later, so with equal domains the whole row stream repeated one lap apart and ten consecutive seeds covered 1,100 of 2,000 rows instead of all of them.
        let domains: [UInt64] = [100, 100, 100, 100, 100]
        var union = Set<[UInt64]>()
        for seed in UInt64(1337) ... 1346 {
            union.formUnion(generateAll(domainSizes: domains, budget: 200, seed: seed).map(\.values))
        }

        #expect(union.count == 2000, "Consecutive seeds overlap: \(union.count)/2000 distinct rows")
    }

    // MARK: - Per-Slice Tracking

    @Test("A narrow slice is covered completely beside a wide parameter")
    func narrowSliceIsCoveredBesideAWideParameter() {
        // 3000 x 6 exceeds the slice threshold and goes untracked, but 6 x 6 does not. Tracking that slice covers all 36 of its pairs within 36 rows; an all-spread generator needs about 60.
        let domains: [UInt64] = [3000, 6, 6]
        let rows = generateAll(domainSizes: domains, budget: 36)

        let pairs = Set(rows.map { [$0.values[1], $0.values[2]] })
        #expect(pairs.count == 36, "Narrow slice covered \(pairs.count)/36 pairs in 36 rows")
    }

    @Test("A wide parameter still spreads while its narrow partners are tracked")
    func wideParameterSpreadsInAHybrid() {
        let domains: [UInt64] = [3000, 6, 6]
        let rows = generateAll(domainSizes: domains, budget: 36)

        let distinct = Set(rows.map { $0.values[0] })
        #expect(distinct.count == 36, "Wide parameter repeated values: \(distinct.count)/36 distinct")
    }

    @Test("An untracked slice keeps the row stream infinite")
    func untrackedSliceKeepsTheStreamInfinite() {
        // The spread reports no exhaustion, so stopping once the tracked pairs are covered would cut a screening run short while the wide parameter was still cycling usefully.
        let domains: [UInt64] = [3000, 6, 6]
        let generator = BalancedCoveringArrayGenerator(domainSizes: domains)

        for _ in 0 ..< 1000 {
            #expect(generator.next() != nil)
        }
    }

    @Test("A wide parameter whose slices all fit still terminates")
    func everySliceTrackedTerminatesDespiteAWideParameter() {
        // 200 x 2 is within the slice threshold, so every slice here is tracked and the generator keeps the greedy path's termination guarantee even though one domain is far above greedyThreshold.
        let domains: [UInt64] = [200, 2, 2, 2]
        let rows = generateAll(domainSizes: domains, budget: 5000)

        #expect(rows.count < 5000, "Expected exhaustion, got \(rows.count) rows")
        verifyTWayCoverage(rows: rows, domainSizes: domains)
    }

    // MARK: - Gain Ceiling

    @Test("A domain whose reciprocal is inexact still reaches optimal coverage")
    func inexactReciprocalDomainReachesOptimalCoverage() {
        // Gains accumulate as Double(uncovered) * (1 / Double(domain)), and for domain 49 that product is 0.99999999999999989, so an exact ceiling comparison never fires. The tolerance that fixes it must not be loose enough to accept a genuinely lower gain, which would cost rows.
        let domains: [UInt64] = [49, 4]
        let rows = generateAll(domainSizes: domains, budget: 1000)

        #expect(rows.count == 196, "Expected the optimal 196 rows, got \(rows.count)")
        verifyTWayCoverage(rows: rows, domainSizes: domains)
    }
}

// MARK: - Helpers

private func generateAll(domainSizes: [UInt64], budget: Int, seed: UInt64 = 0) -> [CoveringArrayRow] {
    let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes, seed: seed)
    var rows: [CoveringArrayRow] = []
    while rows.count < budget, let row = generator.next() {
        rows.append(row)
    }
    return rows
}

private func verifyTWayCoverage(rows: [CoveringArrayRow], domainSizes: [UInt64]) {
    let paramCount = domainSizes.count
    for paramA in 0 ..< paramCount {
        for paramB in (paramA + 1) ..< paramCount {
            var seen = Set<[UInt64]>()
            for row in rows {
                seen.insert([row.values[paramA], row.values[paramB]])
            }
            let expected = domainSizes[paramA] * domainSizes[paramB]
            #expect(
                UInt64(seen.count) == expected,
                "Missing pairwise coverage for (\(paramA), \(paramB)): got \(seen.count), expected \(expected)"
            )
        }
    }
}
