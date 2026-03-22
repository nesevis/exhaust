//
//  CoveringArray.swift
//  Exhaust
//

/// A single row in the covering array, mapping parameter indices to value indices.
public struct CoveringArrayRow: @unchecked Sendable {
    /// `values[i]` is a value index in `0..<parameters[i].domainSize`.
    public var values: [UInt64]

    public init(values: [UInt64]) {
        self.values = values
    }
}

/// A t-way covering array guaranteeing that every t-tuple of parameter values appears in at least one row.
///
/// Generated using the IPOG (In-Parameter-Order-General) algorithm from:
/// Lei & Kacker, "IPOG: A General Strategy for T-Way Software Testing",
/// 14th Annual IEEE International Conference and Workshops on the Engineering of Computer-Based Systems (ECBS 2007).
///
/// The architecture accommodates future extension to ordered t-way coverage via concatenated covering arrays, as described by Kuhn, Raunak & Kacker in "Ordered t-way Combinations for Testing State-based Systems".
public struct CoveringArray: @unchecked Sendable {
    public let strength: Int
    public let rows: [CoveringArrayRow]
    public let profile: FiniteDomainProfile

    /// Returns the strongest covering array that fits within `budget` rows, or `nil` if even t=2 doesn't fit.
    ///
    /// Searches bottom-up (t=2, 3, …) so it can stop as soon as a strength exceeds the budget, avoiding unnecessary IPOG runs at high strengths.
    /// Also skips strengths whose initial seed rows alone exceed the budget (the seed is the exhaustive product of the first `t` parameters).
    ///
    /// - Parameter maxStrength: Upper bound on the interaction strength to try. Defaults to 6. Callers with large per-parameter domains (for example, SCA with argument-aware domains) should pass a lower cap to avoid combinatorially expensive IPOG runs at high strengths.
    public static func bestFitting(budget: UInt64, profile: FiniteDomainProfile, maxStrength: Int = 6) -> CoveringArray? {
        let paramCount = profile.parameters.count
        guard paramCount >= 2 else { return nil }

        var best: CoveringArray?
        for t in 2 ... min(paramCount, maxStrength) {
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
    /// IPOG builds the array incrementally: it starts with an exhaustive enumeration of the first `t` parameters, then extends one parameter at a time via *horizontal growth* (greedily choosing the best value for each existing row) followed by *vertical growth* (adding new rows for any uncovered tuples).
    ///
    /// - Parameters:
    ///   - profile: The finite domain profile describing all parameters.
    ///   - strength: The interaction strength `t` (typically 2 or 3).
    /// - Returns: A covering array, or `nil` if generation fails.
    public static func generate(profile: FiniteDomainProfile, strength: Int, rowBudget: Int? = nil) -> CoveringArray? {
        let params = profile.parameters
        let n = params.count
        guard strength >= 1, strength <= n else { return nil }

        if strength == n {
            return exhaustive(profile: profile)
        }

        var builder = IPOGBuilder(params: params, strength: strength)
        if let budget = rowBudget {
            guard builder.run(rowBudget: budget) else { return nil }
        } else {
            builder.runUnbounded()
        }

        let rows = builder.finalize()
        return CoveringArray(strength: strength, rows: rows, profile: profile)
    }

    /// Returns a per-length partitioned covering array for a boundary profile with a single sequence group,
    /// or nil if the profile has no sequences, has multiple sequences, or doesn't fit within budget.
    ///
    /// Each sub-array contains only the element parameters accessible at that length value. This avoids
    /// the flat IPOG bug where element values are assigned to rows with `sequenceLength=0` (empty arrays).
    public static func bestFittingPerLength(
        budget: UInt64,
        boundaryProfile: BoundaryDomainProfile
    ) -> [(rows: [CoveringArrayRow], profile: BoundaryDomainProfile)]? {
        guard boundaryProfile.hasMultipleSequenceLengths == false else { return nil }

        // Find the sequence length parameter index.
        guard let lengthIndex = boundaryProfile.parameters.indices.first(where: {
            if case .sequenceLength = boundaryProfile.parameters[$0].kind {
                return true
            }
            return false
        }) else {
            return nil
        }

        // Find the sequence node in the original tree to count element params per slot.
        guard let originalTree = boundaryProfile.originalTree,
              let sequenceElements = findSequenceElements(in: originalTree)
        else {
            return nil
        }

        let maxElementSlots = min(2, sequenceElements.count)
        let count0 = maxElementSlots >= 1 ? countElementParams(in: sequenceElements[0]) : 0
        let count1 = maxElementSlots >= 2 ? countElementParams(in: sequenceElements[1]) : 0

        let elem0Range = (lengthIndex + 1) ..< (lengthIndex + 1 + count0)
        let elem1Range = (lengthIndex + 1 + count0) ..< (lengthIndex + 1 + count0 + count1)

        return buildPerLength(
            profile: boundaryProfile,
            sequenceLengthIndex: lengthIndex,
            elem0Range: elem0Range,
            elem1Range: elem1Range,
            budget: budget
        )
    }

    /// Finds the element subtrees of the first `.sequence` node in a choice tree.
    private static func findSequenceElements(in tree: ChoiceTree) -> [ChoiceTree]? {
        switch tree {
        case let .sequence(_, elements, _):
            return elements
        case let .group(children, _):
            for child in children {
                if let found = findSequenceElements(in: child) {
                    return found
                }
            }
            return nil
        case let .selected(inner):
            return findSequenceElements(in: inner)
        case let .bind(inner, _):
            return findSequenceElements(in: inner)
        default:
            return nil
        }
    }

    /// Returns the strongest covering array that fits within `budget` rows for a boundary domain profile, or `nil` if even t=2 doesn't fit.
    public static func bestFitting(budget: UInt64, boundaryProfile: BoundaryDomainProfile) -> CoveringArray? {
        let syntheticParams = boundaryProfile.parameters.map { param in
            FiniteParameter(
                index: param.index,
                domainSize: param.domainSize,
                kind: .chooseBits(range: 0 ... max(param.domainSize, 1) - 1, tag: .uint64)
            )
        }
        var totalSpace: UInt64 = 1
        for param in syntheticParams {
            let (product, overflow) = totalSpace.multipliedReportingOverflow(by: param.domainSize)
            if overflow { totalSpace = .max; break }
            totalSpace = product
        }
        let syntheticProfile = FiniteDomainProfile(
            parameters: syntheticParams,
            totalSpace: totalSpace
        )

        // For 1-parameter boundary profiles, IPOG requires paramCount >= 2.
        // Generate a trivial strength-1 covering array that tests each value.
        if syntheticParams.count == 1 {
            let count = syntheticParams[0].domainSize
            guard count <= budget else { return nil }
            let rows = (0 ..< count).map { CoveringArrayRow(values: [$0]) }
            return CoveringArray(strength: 1, rows: rows, profile: syntheticProfile)
        }

        return bestFitting(budget: budget, profile: syntheticProfile)
    }

    // MARK: - Per-Length Partitioned Construction

    /// Builds separate covering arrays for each sequence length value, each containing only the
    /// element parameters accessible at that length. Returns nil if the total exceeds the budget.
    ///
    /// This fixes the soundness bug where flat IPOG assigns element values to rows with
    /// `sequenceLength=0`, claiming coverage of pairs that are never exercised.
    static func buildPerLength(
        profile: BoundaryDomainProfile,
        sequenceLengthIndex: Int,
        elem0Range: Range<Int>,
        elem1Range: Range<Int>,
        budget: UInt64
    ) -> [(rows: [CoveringArrayRow], profile: BoundaryDomainProfile)]? {
        guard sequenceLengthIndex < profile.parameters.count else {
            return nil
        }
        let lengthParam = profile.parameters[sequenceLengthIndex]

        var subArrays: [(rows: [CoveringArrayRow], profile: BoundaryDomainProfile)] = []
        var remaining = budget

        for lengthValue in lengthParam.values {
            // Build the sub-profile: same parameters, but length pinned to one value
            // and inaccessible element parameters removed.
            var subParams: [BoundaryParameter] = []
            for (index, param) in profile.parameters.enumerated() {
                if index == sequenceLengthIndex {
                    // Pin the length parameter to a single value.
                    subParams.append(BoundaryParameter(
                        index: subParams.count,
                        values: [lengthValue],
                        domainSize: 1,
                        kind: param.kind
                    ))
                } else if elem0Range.contains(index) {
                    // Element 0 params: include only when length >= 1.
                    guard lengthValue >= 1 else { continue }
                    subParams.append(BoundaryParameter(
                        index: subParams.count,
                        values: param.values,
                        domainSize: param.domainSize,
                        kind: param.kind
                    ))
                } else if elem1Range.contains(index) {
                    // Element 1 params: include only when length >= 2.
                    guard lengthValue >= 2 else { continue }
                    subParams.append(BoundaryParameter(
                        index: subParams.count,
                        values: param.values,
                        domainSize: param.domainSize,
                        kind: param.kind
                    ))
                } else {
                    // Non-sequence parameter: always included.
                    subParams.append(BoundaryParameter(
                        index: subParams.count,
                        values: param.values,
                        domainSize: param.domainSize,
                        kind: param.kind
                    ))
                }
            }

            let subProfile = BoundaryDomainProfile(
                parameters: subParams,
                originalTree: profile.originalTree
            )

            guard let covering = bestFitting(budget: remaining, boundaryProfile: subProfile) else {
                return nil
            }
            guard UInt64(covering.rows.count) <= remaining else {
                return nil
            }
            remaining -= UInt64(covering.rows.count)
            subArrays.append((rows: covering.rows, profile: subProfile))
        }

        return subArrays
    }

    /// Counts how many parameters `walkElementTree` would extract from an element subtree.
    ///
    /// Must replicate ``ChoiceTreeAnalysis/walkElementTree(_:elementIndex:parameters:)`` dispatch
    /// logic exactly. Any divergence misaligns element parameter ranges and breaks `paramIndex`
    /// for non-sequence parameters that follow the sequence in tree-walk order.
    /// - SeeAlso: `ChoiceTreeAnalysis.walkElementTree`
    static func countElementParams(in tree: ChoiceTree) -> Int {
        switch tree {
        case .choice:
            // walkElementChoice always appends one parameter.
            return 1

        case .just:
            return 0

        case .group(_, isOpaque: true):
            return 0

        case let .group(children, _):
            if ChoiceTreeAnalysis.isPick(children) {
                // walkPick appends one parameter (the pick itself).
                return 1
            }
            var total = 0
            for child in children {
                total += countElementParams(in: child)
            }
            return total

        case let .selected(inner):
            return countElementParams(in: inner)

        case .bind:
            // walkElementTree treats bind inside element as opaque — zero params.
            return 0

        case .getSize, .resize, .sequence, .branch:
            // walkElementTree rejects these, but if we reach here during counting,
            // treat as zero. The analysis already validated the tree.
            return 0
        }
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

// MARK: - Packed Key Types

/// Packs up to 8 parameter indices (each < 256) into a single `UInt64`, 8 bits per index.
private struct ComboKey: Hashable {
    let packed: UInt64

    init(_ indices: [Int]) {
        var p: UInt64 = 0
        var i = 0
        while i < indices.count {
            p |= UInt64(indices[i]) << (i &* 8)
            i &+= 1
        }
        packed = p
    }
}

/// Packs up to 8 domain values (each < 65536) into two `UInt64`s, 16 bits per value.
private struct ValueKey: Hashable {
    let lo: UInt64
    let hi: UInt64
}

// MARK: - IPOG Builder

/// Internal builder implementing the IPOG algorithm (Lei & Kacker, ECBS 2007).
///
/// Uses `Optional<UInt64>` for don't-care tracking during vertical growth, which the paper denotes as wildcard positions that can be freely assigned.
///
/// Performance optimizations:
/// - Combinations and their packed ComboKeys are pre-computed once in `init` instead of regenerated per call.
/// - "Must-include" combos are generated directly (e.g. for t=2, combos including i are `{(j,i) | j<i}`) instead of filtering all C(n,t) combos.
/// - Dictionary keys use packed inline value types instead of heap-allocated arrays.
/// - Hot-path loops use index-based iteration to avoid iterator overhead.
private struct IPOGBuilder {
    let params: [FiniteParameter]
    let strength: Int
    let n: Int

    /// Working rows with Optional values (nil = don't care).
    var rows: [[UInt64?]]

    /// Tracks covered t-way combinations.
    var covered: CoveredSet

    /// Pre-computed: `allCombos[upToParam]` = all combinations(of: upToParam, choose: strength).
    let allCombos: [[[Int]]]

    /// Pre-computed ComboKeys parallel to `allCombos`.
    let allComboKeys: [[ComboKey]]

    /// Pre-computed: `combosIncluding[i]` = t-combos from `0..<(i+1)` that contain `i`.
    /// Generated directly as (t-1)-combos from `0..<i` with `i` appended.
    let combosIncluding: [[[Int]]]

    /// Pre-computed ComboKeys parallel to `combosIncluding`.
    let combosIncludingKeys: [[ComboKey]]

    init(params: [FiniteParameter], strength: Int) {
        self.params = params
        self.strength = strength
        n = params.count
        rows = []
        covered = CoveredSet()

        var allCombos = Array(repeating: [[Int]](), count: n + 1)
        var allComboKeys = Array(repeating: [ComboKey](), count: n + 1)
        for upTo in strength ... n {
            let combos = combinations(of: upTo, choose: strength)
            allComboKeys[upTo] = combos.map { ComboKey($0) }
            allCombos[upTo] = combos
        }
        self.allCombos = allCombos
        self.allComboKeys = allComboKeys

        var combosIncluding = Array(repeating: [[Int]](), count: n)
        var combosIncludingKeys = Array(repeating: [ComboKey](), count: n)
        for i in (strength - 1) ..< n {
            let combos: [[Int]] = if strength == 1 {
                [[i]]
            } else {
                combinationsAppending(of: i, choose: strength - 1, trailing: i)
            }
            combosIncludingKeys[i] = combos.map { ComboKey($0) }
            combosIncluding[i] = combos
        }
        self.combosIncluding = combosIncluding
        self.combosIncludingKeys = combosIncludingKeys
    }

    /// Runs IPOG without a row budget.
    mutating func runUnbounded() {
        seedInitialRows()
        for i in strength ..< n {
            horizontalGrowth(paramIndex: i)
            verticalGrowth(paramIndex: i)
        }
    }

    /// Runs IPOG with a row budget. Returns `false` (and aborts) if the row
    /// count exceeds the budget at any point during growth.
    mutating func run(rowBudget: Int) -> Bool {
        seedInitialRows()
        if rows.count > rowBudget { return false }
        for i in strength ..< n {
            horizontalGrowth(paramIndex: i)
            verticalGrowth(paramIndex: i)
            if rows.count > rowBudget { return false }
        }
        return true
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

        rows.reserveCapacity(Int(totalCombinations))

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
        let combos = allCombos[strength]
        let keys = allComboKeys[strength]
        for row in rows {
            covered.addAll(row: row, combos: combos, comboKeys: keys)
        }
    }

    // MARK: - Horizontal Growth

    private mutating func horizontalGrowth(paramIndex i: Int) {
        let domainI = params[i].domainSize
        let combos = combosIncluding[i]
        let keys = combosIncludingKeys[i]

        for rowIdx in rows.indices {
            // Choose value for parameter i that covers the most new combinations
            var bestValue: UInt64 = 0
            var bestCount = 0

            for v in 0 ..< domainI {
                rows[rowIdx][i] = v
                let count = covered.countUncovered(row: rows[rowIdx], combos: combos, comboKeys: keys)
                if count > bestCount {
                    bestCount = count
                    bestValue = v
                }
            }

            rows[rowIdx][i] = bestValue
            covered.addAll(row: rows[rowIdx], combos: combos, comboKeys: keys)
        }
    }

    // MARK: - Vertical Growth

    private mutating func verticalGrowth(paramIndex i: Int) {
        let combos = combosIncluding[i]
        let keys = combosIncludingKeys[i]
        let uncoveredTuples = covered.findUncovered(combos: combos, comboKeys: keys, params: params)

        rows.reserveCapacity(rows.count + uncoveredTuples.count)

        for tuple in uncoveredTuples {
            // Try to fit into an existing row
            var fitted = false
            var rowIdx = 0
            while rowIdx < rows.indices.endIndex {
                if canFit(rowIdx: rowIdx, tuple: tuple) {
                    applyTuple(rowIdx: rowIdx, tuple: tuple)
                    covered.addTuple(tuple)
                    fitted = true
                    break
                }
                rowIdx += 1
            }

            if !fitted {
                var newRow = [UInt64?](repeating: nil, count: n)
                let tupleCount = tuple.paramIndices.count
                var j = 0
                while j < tupleCount {
                    newRow[tuple.paramIndices[j]] = tuple.values[j]
                    j &+= 1
                }
                covered.addAll(row: newRow, combos: allCombos[i + 1], comboKeys: allComboKeys[i + 1])
                rows.append(newRow)
            }
        }
    }

    /// Can the tuple be applied without conflicting with existing non-nil values?
    private func canFit(rowIdx: Int, tuple: IndexedTuple) -> Bool {
        let row = rows[rowIdx]
        let count = tuple.paramIndices.count
        var j = 0
        while j < count {
            if let existing = row[tuple.paramIndices[j]], existing != tuple.values[j] {
                return false
            }
            j &+= 1
        }
        return true
    }

    private mutating func applyTuple(rowIdx: Int, tuple: IndexedTuple) {
        let count = tuple.paramIndices.count
        var j = 0
        while j < count {
            rows[rowIdx][tuple.paramIndices[j]] = tuple.values[j]
            j &+= 1
        }
    }
}

// MARK: - Covered Combination Tracking

private struct CoveredSet {
    private var sets: [ComboKey: Set<ValueKey>] = [:]

    mutating func addTuple(_ tuple: IndexedTuple) {
        let key = ComboKey(tuple.paramIndices)
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        var i = 0
        while i < tuple.values.count {
            let v = tuple.values[i]
            if i < 4 {
                lo |= v << (i &* 16)
            } else {
                hi |= v << ((i &- 4) &* 16)
            }
            i &+= 1
        }
        sets[key, default: []].insert(ValueKey(lo: lo, hi: hi))
    }

    mutating func addAll(row: [UInt64?], combos: [[Int]], comboKeys: [ComboKey]) {
        var ci = 0
        while ci < combos.count {
            let combo = combos[ci]
            // Pack values inline to avoid temporary array allocation
            var lo: UInt64 = 0
            var hi: UInt64 = 0
            var allPresent = true
            var i = 0
            while i < combo.count {
                guard let v = row[combo[i]] else { allPresent = false; break }
                if i < 4 {
                    lo |= v << (i &* 16)
                } else {
                    hi |= v << ((i &- 4) &* 16)
                }
                i &+= 1
            }
            if allPresent {
                sets[comboKeys[ci], default: []].insert(ValueKey(lo: lo, hi: hi))
            }
            ci &+= 1
        }
    }

    func countUncovered(row: [UInt64?], combos: [[Int]], comboKeys: [ComboKey]) -> Int {
        var count = 0
        var ci = 0
        while ci < combos.count {
            let combo = combos[ci]
            // Pack values inline to avoid temporary array allocation
            var lo: UInt64 = 0
            var hi: UInt64 = 0
            var allPresent = true
            var i = 0
            while i < combo.count {
                guard let v = row[combo[i]] else { allPresent = false; break }
                if i < 4 {
                    lo |= v << (i &* 16)
                } else {
                    hi |= v << ((i &- 4) &* 16)
                }
                i &+= 1
            }
            if allPresent {
                if sets[comboKeys[ci]]?.contains(ValueKey(lo: lo, hi: hi)) != true {
                    count += 1
                }
            }
            ci &+= 1
        }
        return count
    }

    func findUncovered(combos: [[Int]], comboKeys: [ComboKey], params: [FiniteParameter]) -> [IndexedTuple] {
        var result: [IndexedTuple] = []
        var domainBuffer = [UInt64](repeating: 0, count: 8)
        var valueBuffer = [UInt64](repeating: 0, count: 8)

        var ci = 0
        while ci < combos.count {
            let combo = combos[ci]
            let comboCount = combo.count
            let coveredValues = sets[comboKeys[ci]] ?? []

            var total: UInt64 = 1
            var di = 0
            while di < comboCount {
                let d = params[combo[di]].domainSize
                domainBuffer[di] = d
                let (product, overflow) = total.multipliedReportingOverflow(by: d)
                if overflow { total = .max; break }
                total = product
                di &+= 1
            }

            for idx in 0 ..< total {
                // Decompose mixed-radix index forward into valueBuffer
                var remainder = idx
                var vi = comboCount &- 1
                while vi >= 0 {
                    let d = domainBuffer[vi]
                    valueBuffer[vi] = remainder % d
                    remainder /= d
                    vi &-= 1
                }

                // Build ValueKey inline
                var lo: UInt64 = 0
                var hi: UInt64 = 0
                var ki = 0
                while ki < comboCount {
                    let v = valueBuffer[ki]
                    if ki < 4 {
                        lo |= v << (ki &* 16)
                    } else {
                        hi |= v << ((ki &- 4) &* 16)
                    }
                    ki &+= 1
                }

                let valueKey = ValueKey(lo: lo, hi: hi)
                if !coveredValues.contains(valueKey) {
                    result.append(IndexedTuple(
                        paramIndices: combo,
                        values: Array(valueBuffer[0 ..< comboCount])
                    ))
                }
            }
            ci &+= 1
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

/// Generates all `choose`-sized combinations of indices from `0..<n`, each with `trailing` appended.
///
/// Avoids the intermediate allocation of `combinations(of:choose:).map { $0 + [trailing] }`.
private func combinationsAppending(of n: Int, choose k: Int, trailing: Int) -> [[Int]] {
    guard k <= n, k > 0 else { return [[trailing]] }
    var result: [[Int]] = []
    var current: [Int] = []
    current.reserveCapacity(k + 1)

    func build(start: Int) {
        if current.count == k {
            var combo = current
            combo.append(trailing)
            result.append(combo)
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
