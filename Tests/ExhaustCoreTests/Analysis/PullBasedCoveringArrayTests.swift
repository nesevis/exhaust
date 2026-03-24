//
//  PullBasedCoveringArrayTests.swift
//  Exhaust
//

@_spi(ExhaustInternal) import ExhaustCore
import Testing

@Suite("Pull-Based Covering Array")
struct PullBasedCoveringArrayTests {
    @Test("5 booleans at t=2 covers all pairs")
    func fiveBoolsPairwise() {
        let domains: [UInt64] = [2, 2, 2, 2, 2]
        let rows = generateAll(domainSizes: domains, strength: 2)

        let lowerBound = largestProductOfSubset(domains, size: 2)
        #expect(rows.count >= lowerBound)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 2)
    }

    @Test("Mixed domains at t=2 covers all pairs")
    func mixedDomainsPairwise() {
        let domains: [UInt64] = [2, 3, 4, 2]
        let rows = generateAll(domainSizes: domains, strength: 2)

        let lowerBound = largestProductOfSubset(domains, size: 2)
        #expect(rows.count >= lowerBound)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 2)
    }

    @Test("6 ternary parameters at t=3 covers all triples")
    func sixTernaryStrength3() {
        let domains: [UInt64] = [3, 3, 3, 3, 3, 3]
        let rows = generateAll(domainSizes: domains, strength: 3)

        let lowerBound = largestProductOfSubset(domains, size: 3)
        #expect(rows.count >= lowerBound)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 3)
    }

    @Test("4 binary parameters at t=4 covers all quadruples — exhaustive")
    func fourBinaryStrength4() {
        let domains: [UInt64] = [2, 2, 2, 2]
        let rows = generateAll(domainSizes: domains, strength: 4)

        // t == paramCount: must enumerate the full product space.
        let fullSpace = Int(domains.reduce(1, *))
        #expect(rows.count == fullSpace)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 4)
    }

    @Test("Large seed pair with booleans at t=2")
    func largeSeedPairWithBooleans() {
        let domains: [UInt64] = [8, 8, 2, 2, 2, 2, 2, 2]
        let rows = generateAll(domainSizes: domains, strength: 2)

        let lowerBound = largestProductOfSubset(domains, size: 2)
        #expect(rows.count >= lowerBound)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 2)
    }

    @Test("Symmetric ternary domains at t=2")
    func symmetricTernaryPairwise() {
        let domains: [UInt64] = [3, 3, 3, 3, 3, 3]
        let rows = generateAll(domainSizes: domains, strength: 2)

        let lowerBound = largestProductOfSubset(domains, size: 2)
        #expect(rows.count >= lowerBound)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 2)
    }

    @Test("Determinism — same inputs produce identical row sequence")
    func determinism() {
        let domains: [UInt64] = [3, 4, 2, 5, 3]
        let rows1 = generateAll(domainSizes: domains, strength: 2)
        let rows2 = generateAll(domainSizes: domains, strength: 2)

        #expect(rows1.count == rows2.count)
        for index in 0 ..< rows1.count {
            #expect(rows1[index].values == rows2[index].values)
        }
    }

    @Test("Parameter restoration — values are in original parameter order")
    func parameterRestoration() {
        let domains: [UInt64] = [5, 2, 7, 3]
        let rows = generateAll(domainSizes: domains, strength: 2)

        let lowerBound = largestProductOfSubset(domains, size: 2)
        #expect(rows.count >= lowerBound)

        for row in rows {
            #expect(row.values.count == domains.count)
            for paramIndex in 0 ..< domains.count {
                #expect(
                    row.values[paramIndex] < domains[paramIndex],
                    "Param \(paramIndex) (domain \(domains[paramIndex])) out of range: \(row.values[paramIndex])"
                )
            }
        }

        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 2)
    }

    @Test("Early stop produces valid partial coverage")
    func earlyStop() {
        let domains: [UInt64] = [3, 3, 3, 3, 3, 3]
        var generator = PullBasedCoveringArrayGenerator(domainSizes: domains, strength: 2)
        defer { generator.deallocate() }

        let pullCount = 5
        let totalTuples = totalTWayTuples(domains, strength: 2)
        var rows: [CoveringArrayRow] = []
        var count = 0
        while count < pullCount, let row = generator.next() {
            rows.append(row)
            count += 1
        }

        #expect(rows.count == pullCount)
        // 5 rows cannot cover all C(6,2)×9 = 135 pairwise tuples.
        #expect(generator.totalRemaining > 0)
        #expect(generator.totalRemaining < totalTuples)

        for row in rows {
            #expect(row.values.count == domains.count)
            for paramIndex in 0 ..< domains.count {
                #expect(row.values[paramIndex] < domains[paramIndex])
            }
        }
    }

    @Test("Generator returns nil when fully covered")
    func exhaustionReturnsNil() {
        let domains: [UInt64] = [2, 2, 2]
        var generator = PullBasedCoveringArrayGenerator(domainSizes: domains, strength: 2)
        defer { generator.deallocate() }

        let totalTuples = totalTWayTuples(domains, strength: 2)
        var count = 0
        while generator.next() != nil {
            count += 1
            if count > totalTuples { break }
        }

        #expect(generator.totalRemaining == 0)
        #expect(generator.next() == nil)
        // Rows needed must not exceed the total tuple count (each row covers at least 1).
        #expect(count <= totalTuples)
    }

    @Test("Bound5-scale parameters at t=2")
    func bound5Scale() {
        let domains: [UInt64] = [3, 3, 3, 3, 3, 5, 5, 5, 5, 5, 5, 5, 5]
        let rows = generateAll(domainSizes: domains, strength: 2)

        let lowerBound = largestProductOfSubset(domains, size: 2)
        #expect(rows.count >= lowerBound)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 2)
    }

    @Test("Two parameters at t=2 requires full product")
    func twoParametersFullProduct() {
        let domains: [UInt64] = [6, 5]
        let rows = generateAll(domainSizes: domains, strength: 2)

        // With only 2 params and t=2, every row covers exactly one new pair.
        // Full coverage requires the complete product.
        let fullSpace = Int(domains.reduce(1, *))
        #expect(rows.count == fullSpace)
        verifyTWayCoverage(rows: rows, domainSizes: domains, strength: 2)
    }
}

// MARK: - Helpers

private func generateAll(domainSizes: [UInt64], strength: Int) -> [CoveringArrayRow] {
    var generator = PullBasedCoveringArrayGenerator(domainSizes: domainSizes, strength: strength)
    defer { generator.deallocate() }

    let upperBound = totalTWayTuples(domainSizes, strength: strength)
    var rows: [CoveringArrayRow] = []
    while let row = generator.next() {
        rows.append(row)
        if rows.count > upperBound { break }
    }
    return rows
}

/// The largest product of any `size` domains — a lower bound on the covering array row count.
private func largestProductOfSubset(_ domains: [UInt64], size: Int) -> Int {
    let sorted = domains.sorted(by: >)
    var product: UInt64 = 1
    for index in 0 ..< min(size, sorted.count) {
        product *= sorted[index]
    }
    return Int(product)
}

/// Total number of t-tuples across all C(k,t) parameter combinations.
private func totalTWayTuples(_ domains: [UInt64], strength: Int) -> Int {
    var total = 0
    for combo in allCombinations(of: domains.count, choose: strength) {
        var product = 1
        for index in combo {
            product *= Int(domains[index])
        }
        total += product
    }
    return total
}

private func verifyTWayCoverage(rows: [CoveringArrayRow], domainSizes: [UInt64], strength: Int) {
    let paramCount = domainSizes.count
    for combo in allCombinations(of: paramCount, choose: strength) {
        var seen = Set<[UInt64]>()
        for row in rows {
            let tuple = combo.map { row.values[$0] }
            seen.insert(tuple)
        }

        var expected: UInt64 = 1
        for index in combo {
            expected *= domainSizes[index]
        }

        #expect(
            UInt64(seen.count) == expected,
            "Missing coverage for combination \(combo): got \(seen.count), expected \(expected)"
        )
    }
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
