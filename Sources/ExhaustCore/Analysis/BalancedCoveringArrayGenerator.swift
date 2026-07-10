// MARK: - Academic Background

// Density-based pairwise covering array generator with dynamic factor ordering.
//
// The standard Density (Bryce & Colbourn, 2009) algorithm fills columns left-to-right in a fixed order. This starves later parameters under partial budgets: with three parameters with equal domains at budget 200, the first two reach 100% value coverage while the third sits at 5%.
//
// This generator addresses the starvation by choosing which parameter to fill next based on the density signal itself: the parameter whose best candidate covers the most new pairs goes first. When multiple parameters have equal gain (common with equal-sized domains), a cycled start offset rotates which parameter wins the tie, ensuring each parameter gets equal opportunity to be filled first across successive rows.
//
// The coverage state is shared across all rows: each row's greedy choices see every pair covered by prior rows, so no effort is wasted on duplicates.
//
// When any clamped domain exceeds ``greedyThreshold``, the generator switches to a deterministic spread: each parameter is assigned a value via prime-stride cycling, giving diverse coverage in O(paramCount) per row without greedy evaluation or pairwise tracking. This avoids the O(params x domain x slices) cost that dominates for large domains where pairwise coverage is negligible relative to the budget.

/// Pairwise covering array generator with dynamic factor ordering for balanced parameter coverage.
///
/// Emits one row at a time via ``next()``, greedily selecting values to maximize new pairwise coverage. The fill order is not fixed: each step picks the (parameter, value) pair with the highest gain across all unfilled parameters. A cycled start offset breaks ties so that each parameter takes turns in the favored position.
///
/// When any domain exceeds ``greedyThreshold`` after clamping, switches to a deterministic spread that cycles values via prime strides. This avoids allocating pairwise bit vectors and running greedy evaluation for domains where the coverage budget cannot meaningfully cover the pairwise space.
///
/// Supports strength 2 (pairwise) only. For exhaustive coverage at higher strengths, use ``PullBasedCoveringArrayGenerator``.
package final class BalancedCoveringArrayGenerator {
    /// Per-parameter domain sizes above this value are clamped to keep pairwise bit vector allocations bounded.
    package static let maxDomainSize = 16384

    // Greedy fill evaluates every candidate value for every unfilled parameter per row — O(params x domain x slices). For small domains this is fast and produces near-optimal covering arrays that exhaust all pairs early. For large domains the pairwise space (d^2 per slice) dwarfs any practical budget, so greedy optimization spends most of its time distinguishing between negligible coverage fractions. At domain 64 the pairwise space is 4,096 per slice; a typical budget of 200 covers ~5%, the point where adaptive selection stops outperforming uniform spread.
    //
    // Below the threshold: greedy fill with full pairwise tracking. Terminates when all pairs are covered.
    // Above the threshold: deterministic spread via coprime strides. No bit vectors, no coverage tracking. Each parameter cycles through all domain values (coprime stride guarantees full coverage), and different strides across parameters ensure distinct pairwise tuples per row. Uniform but not adaptive — may revisit covered pairs while others remain uncovered.

    /// Domains above this threshold use deterministic spread instead of greedy pairwise optimization.
    package static let greedyThreshold = 64

    private let paramCount: Int
    private let domainSizes: [Int]
    private let useGreedy: Bool
    private let spreadStrides: [Int]
    private var slices: [PairwiseSlice]
    private let slicesByParam: [[Int]]
    /// Scratch buffer for per-value gains during greedy fill, sized to the largest domain. Reused across rows to avoid per-row allocation.
    private let gainScratch: UnsafeMutablePointer<Double>
    /// Total number of uncovered pairwise tuples across all slices. Always positive on the fast path.
    private(set) var totalRemaining: Int
    private var rowCount: Int

    /// Creates a balanced covering array generator for pairwise coverage.
    ///
    /// Values above ``maxDomainSize`` are clamped to prevent excessive memory allocation in pairwise bit vectors. When any clamped domain exceeds the greedy threshold, the generator uses a deterministic spread instead of greedy pairwise optimization.
    ///
    /// - Parameters:
    ///   - domainSizes: The number of distinct values for each parameter, in original order.
    ///   - greedyThreshold: Per-domain size above which the generator falls back to deterministic spread. Defaults to ``greedyThreshold``. Pass a higher value when the parameter count is small enough that the pairwise bit vector memory (proportional to `paramCount² × maxDomain²`) is acceptable.
    package init(domainSizes: [UInt64], greedyThreshold: Int? = nil) {
        let effectiveThreshold = greedyThreshold ?? Self.greedyThreshold
        paramCount = domainSizes.count
        let perParamCap = Self.maxDomainSize / max(paramCount, 1)
        self.domainSizes = domainSizes.map { min(Int($0), perParamCap) }

        let maxDomain = self.domainSizes.max() ?? 0
        useGreedy = maxDomain <= effectiveThreshold

        guard useGreedy else {
            spreadStrides = self.domainSizes.enumerated().map { param, domain in
                var stride = 2 &* param &+ 1
                while Self.gcd(stride, domain) != 1 {
                    stride &+= 2
                }
                return stride
            }
            slices = []
            slicesByParam = []
            gainScratch = .allocate(capacity: 1)
            gainScratch.initialize(to: 0)
            totalRemaining = 1
            rowCount = 0
            return
        }
        spreadStrides = []
        gainScratch = .allocate(capacity: max(maxDomain, 1))
        gainScratch.initialize(repeating: 0, count: max(maxDomain, 1))

        var allSlices: [PairwiseSlice] = []
        allSlices.reserveCapacity(self.domainSizes.count * (self.domainSizes.count - 1) / 2)
        var total = 0

        for first in 0 ..< self.domainSizes.count {
            for second in (first + 1) ..< self.domainSizes.count {
                let sizeA = self.domainSizes[first]
                let sizeB = self.domainSizes[second]
                let tupleCount = sizeA * sizeB
                allSlices.append(PairwiseSlice(
                    paramA: first,
                    paramB: second,
                    domainA: sizeA,
                    domainB: sizeB,
                    bits: BalancedBitVector(bitCount: tupleCount),
                    rowUncovered: UncoveredCounts(count: sizeA, initialValue: sizeB),
                    columnUncovered: UncoveredCounts(count: sizeB, initialValue: sizeA),
                    remaining: tupleCount
                ))
                total += tupleCount
            }
        }

        slices = allSlices

        var byParam = [[Int]](repeating: [], count: self.domainSizes.count)
        for (index, slice) in allSlices.enumerated() {
            byParam[slice.paramA].append(index)
            byParam[slice.paramB].append(index)
        }
        slicesByParam = byParam
        totalRemaining = total
        rowCount = 0
    }

    /// Returns the next row, or `nil` if all pairs are covered (greedy path only).
    package func next() -> CoveringArrayRow? {
        if totalRemaining == 0 { return nil }

        if useGreedy {
            return nextGreedy()
        }
        return nextSpread()
    }

    deinit {
        for index in 0 ..< slices.count {
            slices[index].bits.deallocate()
            slices[index].rowUncovered.deallocate()
            slices[index].columnUncovered.deallocate()
        }
        gainScratch.deallocate()
    }

    // MARK: - Greedy Fill

    private func nextGreedy() -> CoveringArrayRow {
        var row = [UInt64](repeating: 0, count: paramCount)
        var filled = [Bool](repeating: false, count: paramCount)
        let startParam = rowCount % paramCount
        // Each slice contributes at most 1 to a candidate's gain, so no candidate can exceed the number of slices its parameter participates in. Ties never replace an earlier best, so scanning can stop as soon as a candidate reaches this ceiling — the selected (parameter, value) is identical to a full scan.
        let maxPossibleGain = Double(paramCount - 1)

        slices.withUnsafeBufferPointer { sliceBuffer in
            for _ in 0 ..< paramCount {
                var bestParam = -1
                var bestValue = 0
                var bestGain = -1.0

                search: for offset in 0 ..< paramCount {
                    let param = (startParam &+ offset) % paramCount
                    guard filled[param] == false else { continue }
                    let domain = domainSizes[param]

                    fillGains(
                        param: param, domain: domain, row: row, filled: filled,
                        sliceBuffer: sliceBuffer
                    )

                    var value = 0
                    while value < domain {
                        let gain = gainScratch[value]
                        if gain > bestGain {
                            bestGain = gain
                            bestParam = param
                            bestValue = value
                            if gain >= maxPossibleGain { break search }
                        }
                        value &+= 1
                    }
                }

                guard bestParam >= 0 else { break }
                row[bestParam] = UInt64(bestValue)
                filled[bestParam] = true
            }
        }

        markCoverage(row)
        rowCount += 1
        return CoveringArrayRow(values: row)
    }

    // MARK: - Deterministic Spread

    private func nextSpread() -> CoveringArrayRow {
        var row = [UInt64](repeating: 0, count: paramCount)
        for param in 0 ..< paramCount {
            row[param] = UInt64((rowCount &* spreadStrides[param] &+ param) % domainSizes[param])
        }
        rowCount += 1
        return CoveringArrayRow(values: row)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            let temp = y
            y = x % y
            x = temp
        }
        return x
    }

    // MARK: - Gain Computation

    /// Fills ``gainScratch`` with the coverage gain of every candidate value for `param`, given the partially filled row.
    ///
    /// For each pairwise slice involving `param`: if the other parameter is already filled, the gain is exact (1 per uncovered pair). If the other parameter is unfilled, the gain is the precomputed marginal uncovered count times the reciprocal of the other parameter's domain size — matching Bryce and Colbourn's unrestricted density weighting without iterating the domain.
    ///
    /// Computing the whole domain per slice keeps the inner loops tight: slice metadata and the filled/unfilled branch are resolved once per slice instead of once per (value, slice) pair. Contributions accumulate in slice order for every value, so the floating-point sums match a per-value traversal exactly.
    private func fillGains(
        param: Int,
        domain: Int,
        row: [UInt64],
        filled: [Bool],
        sliceBuffer: UnsafeBufferPointer<PairwiseSlice>
    ) {
        var value = 0
        while value < domain {
            gainScratch[value] = 0
            value &+= 1
        }

        for sliceIndex in slicesByParam[param] {
            let slice = sliceBuffer[sliceIndex]
            // A fully covered slice contributes zero on both the exact and marginal branches.
            if slice.remaining == 0 { continue }

            if slice.paramA == param {
                if filled[slice.paramB] {
                    // Strided bit tests: pair index for candidate v is v * domainB + rowB.
                    var index = Int(row[slice.paramB])
                    var candidate = 0
                    while candidate < domain {
                        if slice.bits.isSet(UInt32(index)) == false {
                            gainScratch[candidate] += 1
                        }
                        index &+= slice.domainB
                        candidate &+= 1
                    }
                } else {
                    let inverseDomain = slice.inverseDomainB
                    let uncovered = slice.rowUncovered
                    var candidate = 0
                    while candidate < domain {
                        gainScratch[candidate] += Double(uncovered[candidate]) * inverseDomain
                        candidate &+= 1
                    }
                }
            } else {
                if filled[slice.paramA] {
                    // Contiguous bit tests: pair index for candidate v is rowA * domainB + v.
                    var index = Int(row[slice.paramA]) &* slice.domainB
                    var candidate = 0
                    while candidate < domain {
                        if slice.bits.isSet(UInt32(index)) == false {
                            gainScratch[candidate] += 1
                        }
                        index &+= 1
                        candidate &+= 1
                    }
                } else {
                    let inverseDomain = slice.inverseDomainA
                    let uncovered = slice.columnUncovered
                    var candidate = 0
                    while candidate < domain {
                        gainScratch[candidate] += Double(uncovered[candidate]) * inverseDomain
                        candidate &+= 1
                    }
                }
            }
        }
    }

    // MARK: - Coverage Marking

    /// Marks all pairwise tuples in the given row as covered and updates marginal counts.
    private func markCoverage(_ row: [UInt64]) {
        for index in 0 ..< slices.count {
            let valueA = Int(row[slices[index].paramA])
            let valueB = Int(row[slices[index].paramB])
            let flatIndex = UInt32(valueA &* slices[index].domainB &+ valueB)
            if slices[index].bits.set(flatIndex) {
                slices[index].remaining &-= 1
                slices[index].rowUncovered[valueA] &-= 1
                slices[index].columnUncovered[valueB] &-= 1
                totalRemaining &-= 1
            }
        }
    }
}

// MARK: - Bit Vector

/// Bit vector with unsafe pointer storage for pairwise coverage tracking.
///
/// Callers must invoke ``deallocate()`` before the vector is discarded.
private struct BalancedBitVector {
    private let storage: UnsafeMutablePointer<UInt64>
    private let wordCount: Int

    init(bitCount: Int) {
        let words = max((bitCount &+ 63) &>> 6, 1)
        wordCount = words
        storage = .allocate(capacity: words)
        storage.initialize(repeating: 0, count: words)
    }

    @inline(__always)
    func isSet(_ index: UInt32) -> Bool {
        let word = Int(index &>> 6)
        let bit = index & 63
        return (storage[word] &>> bit) & 1 != 0
    }

    @inline(__always)
    mutating func set(_ index: UInt32) -> Bool {
        let word = Int(index &>> 6)
        let bit = index & 63
        let mask: UInt64 = 1 &<< bit
        let old = storage[word]
        if old & mask != 0 { return false }
        storage[word] = old | mask
        return true
    }

    func deallocate() {
        storage.deinitialize(count: wordCount)
        storage.deallocate()
    }
}

// MARK: - Uncovered Counts

/// Marginal uncovered-tuple counters with unsafe pointer storage.
///
/// Plain-data storage keeps ``PairwiseSlice`` free of reference-counted fields, so reading a slice in the greedy fill's inner loop is a trivial copy with no retain/release traffic. Callers must invoke ``deallocate()`` before the counts are discarded.
private struct UncoveredCounts {
    private let storage: UnsafeMutablePointer<Int>

    init(count: Int, initialValue: Int) {
        storage = .allocate(capacity: max(count, 1))
        storage.initialize(repeating: initialValue, count: max(count, 1))
    }

    @inline(__always)
    subscript(index: Int) -> Int {
        get { storage[index] }
        nonmutating set { storage[index] = newValue }
    }

    func deallocate() {
        storage.deallocate()
    }
}

// MARK: - Pairwise Slice

/// Tracks pairwise coverage for one (paramA, paramB) combination.
///
/// All fields are plain data (no reference-counted storage) so the greedy fill can read slices by value without ARC overhead.
private struct PairwiseSlice {
    let paramA: Int
    let paramB: Int
    let domainA: Int
    let domainB: Int

    /// Bit vector indexed as `valueA * domainB + valueB`. A set bit means the pair is covered.
    var bits: BalancedBitVector

    /// `rowUncovered[a]` is the number of uncovered tuples in row `a` (how many values of paramB have not been paired with `a`).
    var rowUncovered: UncoveredCounts

    /// `columnUncovered[b]` is the number of uncovered tuples in column `b` (how many values of paramA have not been paired with `b`).
    var columnUncovered: UncoveredCounts

    var remaining: Int

    /// Reciprocals of the domain sizes, precomputed so the density weighting in the greedy fill multiplies instead of divides.
    let inverseDomainA: Double
    let inverseDomainB: Double

    init(
        paramA: Int,
        paramB: Int,
        domainA: Int,
        domainB: Int,
        bits: BalancedBitVector,
        rowUncovered: UncoveredCounts,
        columnUncovered: UncoveredCounts,
        remaining: Int
    ) {
        self.paramA = paramA
        self.paramB = paramB
        self.domainA = domainA
        self.domainB = domainB
        self.bits = bits
        self.rowUncovered = rowUncovered
        self.columnUncovered = columnUncovered
        self.remaining = remaining
        inverseDomainA = 1.0 / Double(domainA)
        inverseDomainB = 1.0 / Double(domainB)
    }
}
