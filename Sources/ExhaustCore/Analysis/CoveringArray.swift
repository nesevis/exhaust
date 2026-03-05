//
//  CoveringArray.swift
//  Exhaust
//

/// A single row in the covering array, mapping parameter indices to value indices.
@_spi(ExhaustInternal) public struct CoveringArrayRow: @unchecked Sendable {
    /// `values[i]` is a value index in `0..<parameters[i].domainSize`.
    @_spi(ExhaustInternal) public var values: [UInt64]
}

/// A t-way covering array guaranteeing that every t-tuple of parameter values
/// appears in at least one row.
///
/// Generated using the IPOG (In-Parameter-Order-General) algorithm from:
/// Lei & Kacker, "IPOG: A General Strategy for T-Way Software Testing",
/// 14th Annual IEEE International Conference and Workshops on the
/// Engineering of Computer-Based Systems (ECBS 2007).
///
/// The architecture accommodates future extension to ordered t-way coverage
/// via concatenated covering arrays, as described by Kuhn, Raunak & Kacker
/// in "Ordered t-way Combinations for Testing State-based Systems".
@_spi(ExhaustInternal) public struct CoveringArray: @unchecked Sendable {
    @_spi(ExhaustInternal) public let strength: Int
    @_spi(ExhaustInternal) public let rows: [CoveringArrayRow]
    @_spi(ExhaustInternal) public let profile: FiniteDomainProfile

    /// Returns the strongest covering array that fits within `budget` rows,
    /// or `nil` if even t=2 doesn't fit.
    ///
    /// Searches bottom-up (t=2, 3, …) so it can stop as soon as a strength
    /// exceeds the budget, avoiding unnecessary IPOG runs at high strengths.
    /// Also skips strengths whose initial seed rows alone exceed the budget
    /// (the seed is the exhaustive product of the first `t` parameters).
    public static func bestFitting(budget: UInt64, profile: FiniteDomainProfile) -> CoveringArray? {
        let paramCount = profile.parameters.count
        guard paramCount >= 2 else { return nil }

        var best: CoveringArray?
        for t in 2 ... min(paramCount, 6) {
            // Quick reject: the initial seed is the product of the first t domains.
            // If that alone exceeds the budget, higher strengths will only be worse.
            var seedSize: UInt64 = 1
            var tooBig = false
            for i in 0 ..< t {
                let (product, overflow) = seedSize.multipliedReportingOverflow(by: profile.parameters[i].domainSize)
                if overflow || product > budget { tooBig = true; break }
                seedSize = product
            }
            if tooBig { break }

            guard let covering = generate(profile: profile, strength: t) else { continue }
            if UInt64(covering.rows.count) <= budget {
                best = covering
            } else {
                break // higher strengths will only produce more rows
            }
        }
        return best
    }

    /// Generates a covering array using the IPOG algorithm (Lei & Kacker, ECBS 2007).
    ///
    /// IPOG builds the array incrementally: it starts with an exhaustive enumeration
    /// of the first `t` parameters, then extends one parameter at a time via
    /// *horizontal growth* (greedily choosing the best value for each existing row)
    /// followed by *vertical growth* (adding new rows for any uncovered tuples).
    ///
    /// - Parameters:
    ///   - profile: The finite domain profile describing all parameters.
    ///   - strength: The interaction strength `t` (typically 2 or 3).
    /// - Returns: A covering array, or `nil` if generation fails.
    public static func generate(profile: FiniteDomainProfile, strength: Int) -> CoveringArray? {
        let params = profile.parameters
        let n = params.count
        guard strength >= 1, strength <= n else { return nil }

        if strength == n {
            return exhaustive(profile: profile)
        }

        var builder = IPOGBuilder(params: params, strength: strength)
        builder.run()

        let rows = builder.finalize()
        return CoveringArray(strength: strength, rows: rows, profile: profile)
    }

    // MARK: - Exhaustive Enumeration

    private static func exhaustive(profile: FiniteDomainProfile) -> CoveringArray {
        let params = profile.parameters
        var rows: [CoveringArrayRow] = []

        var totalCombinations: UInt64 = 1
        for p in params {
            let (product, overflow) = totalCombinations.multipliedReportingOverflow(by: p.domainSize)
            guard !overflow else { return CoveringArray(strength: params.count, rows: [], profile: profile) }
            totalCombinations = product
        }

        rows.reserveCapacity(Int(totalCombinations))

        for combo in 0 ..< totalCombinations {
            var values = [UInt64](repeating: 0, count: params.count)
            var remainder = combo
            for idx in (0 ..< params.count).reversed() {
                let domain = params[idx].domainSize
                values[idx] = remainder % domain
                remainder /= domain
            }
            rows.append(CoveringArrayRow(values: values))
        }

        return CoveringArray(strength: params.count, rows: rows, profile: profile)
    }
}

// MARK: - IPOG Builder

/// Internal builder implementing the IPOG algorithm (Lei & Kacker, ECBS 2007).
///
/// Uses `Optional<UInt64>` for don't-care tracking during vertical growth,
/// which the paper denotes as wildcard positions that can be freely assigned.
private struct IPOGBuilder {
    let params: [FiniteParameter]
    let strength: Int
    let n: Int

    /// Working rows with Optional values (nil = don't care).
    var rows: [[UInt64?]]

    /// Tracks covered t-way combinations.
    var covered: CoveredSet

    init(params: [FiniteParameter], strength: Int) {
        self.params = params
        self.strength = strength
        self.n = params.count
        self.rows = []
        self.covered = CoveredSet()
    }

    mutating func run() {
        // Step 1: Start with exhaustive combinations of first `t` parameters
        seedInitialRows()

        // Step 2: Horizontal + vertical growth for parameters t..<n
        for i in strength ..< n {
            horizontalGrowth(paramIndex: i)
            verticalGrowth(paramIndex: i)
        }
    }

    /// Convert working rows to final CoveringArrayRow, filling don't-cares with 0.
    func finalize() -> [CoveringArrayRow] {
        rows.map { row in
            CoveringArrayRow(values: row.map { $0 ?? 0 })
        }
    }

    // MARK: - Initial Seed

    private mutating func seedInitialRows() {
        var totalCombinations: UInt64 = 1
        for idx in 0 ..< strength {
            totalCombinations *= params[idx].domainSize
        }

        for combo in 0 ..< totalCombinations {
            var row = [UInt64?](repeating: nil, count: n)
            var remainder = combo
            for idx in (0 ..< strength).reversed() {
                let domain = params[idx].domainSize
                row[idx] = remainder % domain
                remainder /= domain
            }
            rows.append(row)
        }

        // Register all t-way combos from initial rows
        for row in rows {
            covered.addAll(row: row, strength: strength, upToParam: strength)
        }
    }

    // MARK: - Horizontal Growth

    private mutating func horizontalGrowth(paramIndex i: Int) {
        let domainI = params[i].domainSize

        for rowIdx in rows.indices {
            // Choose value for parameter i that covers the most new combinations
            var bestValue: UInt64 = 0
            var bestCount = 0

            for v in 0 ..< domainI {
                rows[rowIdx][i] = v
                let count = covered.countUncovered(
                    row: rows[rowIdx],
                    mustInclude: i,
                    strength: strength,
                    upToParam: i + 1
                )
                if count > bestCount {
                    bestCount = count
                    bestValue = v
                }
            }

            rows[rowIdx][i] = bestValue
            covered.addIncluding(
                row: rows[rowIdx],
                mustInclude: i,
                strength: strength,
                upToParam: i + 1
            )
        }
    }

    // MARK: - Vertical Growth

    private mutating func verticalGrowth(paramIndex i: Int) {
        let uncoveredTuples = covered.findUncovered(
            mustInclude: i,
            strength: strength,
            upToParam: i + 1,
            params: params
        )

        for tuple in uncoveredTuples {
            // Try to fit into an existing row
            var fitted = false
            for rowIdx in rows.indices {
                if canFit(rowIdx: rowIdx, tuple: tuple) {
                    applyTuple(rowIdx: rowIdx, tuple: tuple)
                    covered.addTuple(tuple)
                    fitted = true
                    break
                }
            }

            if !fitted {
                var newRow = [UInt64?](repeating: nil, count: n)
                for (paramIdx, value) in zip(tuple.paramIndices, tuple.values) {
                    newRow[paramIdx] = value
                }
                covered.addAll(row: newRow, strength: strength, upToParam: i + 1)
                rows.append(newRow)
            }
        }
    }

    /// Can the tuple be applied without conflicting with existing non-nil values?
    private func canFit(rowIdx: Int, tuple: IndexedTuple) -> Bool {
        let row = rows[rowIdx]
        for (paramIdx, value) in zip(tuple.paramIndices, tuple.values) {
            if let existing = row[paramIdx], existing != value {
                return false
            }
        }
        return true
    }

    private mutating func applyTuple(rowIdx: Int, tuple: IndexedTuple) {
        for (paramIdx, value) in zip(tuple.paramIndices, tuple.values) {
            rows[rowIdx][paramIdx] = value
        }
    }
}

// MARK: - Covered Combination Tracking

private struct CoveredSet {
    private var sets: [ComboKey: Set<ValueKey>] = [:]

    private struct ComboKey: Hashable {
        let indices: [Int]
    }

    private struct ValueKey: Hashable {
        let values: [UInt64]
    }

    mutating func addTuple(_ tuple: IndexedTuple) {
        let key = ComboKey(indices: tuple.paramIndices)
        let valueKey = ValueKey(values: tuple.values)
        sets[key, default: []].insert(valueKey)
    }

    mutating func addAll(row: [UInt64?], strength: Int, upToParam: Int) {
        for combo in combinations(of: upToParam, choose: strength) {
            // Only add if all values in the combo are non-nil
            var values: [UInt64] = []
            var allPresent = true
            for idx in combo {
                guard let v = row[idx] else { allPresent = false; break }
                values.append(v)
            }
            guard allPresent else { continue }

            let key = ComboKey(indices: combo)
            let valueKey = ValueKey(values: values)
            sets[key, default: []].insert(valueKey)
        }
    }

    mutating func addIncluding(row: [UInt64?], mustInclude: Int, strength: Int, upToParam: Int) {
        for combo in combinations(of: upToParam, choose: strength) {
            guard combo.contains(mustInclude) else { continue }

            var values: [UInt64] = []
            var allPresent = true
            for idx in combo {
                guard let v = row[idx] else { allPresent = false; break }
                values.append(v)
            }
            guard allPresent else { continue }

            let key = ComboKey(indices: combo)
            let valueKey = ValueKey(values: values)
            sets[key, default: []].insert(valueKey)
        }
    }

    func countUncovered(row: [UInt64?], mustInclude: Int, strength: Int, upToParam: Int) -> Int {
        var count = 0
        for combo in combinations(of: upToParam, choose: strength) {
            guard combo.contains(mustInclude) else { continue }

            var values: [UInt64] = []
            var allPresent = true
            for idx in combo {
                guard let v = row[idx] else { allPresent = false; break }
                values.append(v)
            }
            guard allPresent else { continue }

            let key = ComboKey(indices: combo)
            let valueKey = ValueKey(values: values)
            if sets[key]?.contains(valueKey) != true {
                count += 1
            }
        }
        return count
    }

    func findUncovered(
        mustInclude: Int,
        strength: Int,
        upToParam: Int,
        params: [FiniteParameter],
    ) -> [IndexedTuple] {
        var result: [IndexedTuple] = []
        for combo in combinations(of: upToParam, choose: strength) {
            guard combo.contains(mustInclude) else { continue }
            let key = ComboKey(indices: combo)
            let coveredValues = sets[key] ?? []

            let domains = combo.map { params[$0].domainSize }
            var total: UInt64 = 1
            for d in domains {
                let (product, overflow) = total.multipliedReportingOverflow(by: d)
                guard !overflow else { continue }
                total = product
            }

            for idx in 0 ..< total {
                var values: [UInt64] = []
                var remainder = idx
                for i in (0 ..< combo.count).reversed() {
                    values.append(remainder % domains[i])
                    remainder /= domains[i]
                }
                values.reverse()

                let valueKey = ValueKey(values: values)
                if !coveredValues.contains(valueKey) {
                    result.append(IndexedTuple(paramIndices: combo, values: values))
                }
            }
        }
        return result
    }
}

private struct IndexedTuple {
    let paramIndices: [Int]
    let values: [UInt64]
}

/// Generates all `choose`-sized combinations of indices from `0..<n`.
private func combinations(of n: Int, choose k: Int) -> [[Int]] {
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
