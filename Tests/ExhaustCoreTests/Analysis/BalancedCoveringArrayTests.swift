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

    // MARK: - Fast Path (domains > greedyThreshold)

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
}

// MARK: - Helpers

private func generateAll(domainSizes: [UInt64], budget: Int) -> [CoveringArrayRow] {
    let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
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
