import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Covering array contracts")
struct CoveringArrayContractTests {
    @Test("Rows cover every pair in bounds and repeat deterministically", arguments: [false, true])
    func pairwiseContract(balanced: Bool) throws {
        let domains = Gen.arrayOf(Gen.choose(in: UInt64(2) ... 8), within: 2 ... 6)
        try exhaustCheck(domains, maxIterations: 100) { domainSizes in
            let rows = collectRows(domainSizes: domainSizes, balanced: balanced)
            let repeated = collectRows(domainSizes: domainSizes, balanced: balanced)
            let failures = coveringArrayFailures(rows: rows, domainSizes: domainSizes)
            #expect(failures.isEmpty, "\(failures)")
            return failures.isEmpty && rows.map(\.values) == repeated.map(\.values)
        }
    }
}

/// Bounds both implementations by the number of pairs; every productive row must cover at least one new pair in these small domains.
private func collectRows(domainSizes: [UInt64], balanced: Bool) -> [CoveringArrayRow] {
    let balancedGenerator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
    let pullGenerator = PullBasedCoveringArrayGenerator(domainSizes: domainSizes, strength: 2)
    let limit = parameterCombinations(of: domainSizes.count, choose: 2)
        .reduce(0) { $0 + Int(domainSizes[$1[0]] * domainSizes[$1[1]]) }
    var rows: [CoveringArrayRow] = []
    while let row = balanced ? balancedGenerator.next() : pullGenerator.next() {
        rows.append(row)
        if rows.count > limit {
            Issue.record("Covering array did not terminate within \(limit) rows")
            break
        }
    }
    return rows
}

/// Reports malformed rows and missing tuples using the same oracle for examples and generated contracts.
func coveringArrayFailures(rows: [CoveringArrayRow], domainSizes: [UInt64], strength: Int = 2) -> [String] {
    guard rows.allSatisfy({ row in
        row.values.count == domainSizes.count && zip(row.values, domainSizes).allSatisfy { $0 < $1 }
    }) else {
        return ["A row has the wrong width or an out-of-domain value"]
    }
    return parameterCombinations(of: domainSizes.count, choose: strength).compactMap { parameters in
        let seen = Set(rows.map { row in parameters.map { row.values[$0] } })
        let expected = parameters.reduce(UInt64(1)) { $0 * domainSizes[$1] }
        return UInt64(seen.count) == expected ? nil
            : "Parameters \(parameters) cover \(seen.count) of \(expected) tuples"
    }
}

/// Enumerates parameter subsets independently of the covering-array implementations.
func parameterCombinations(of count: Int, choose size: Int) -> [[Int]] {
    guard size > 0, size <= count else {
        return []
    }
    var combinations: [[Int]] = []
    func append(start: Int, prefix: [Int]) {
        if prefix.count == size {
            combinations.append(prefix)
            return
        }
        for index in start ... count - (size - prefix.count) {
            append(start: index + 1, prefix: prefix + [index])
        }
    }
    append(start: 0, prefix: [])
    return combinations
}
