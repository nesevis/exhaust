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
    /// Total number of uncovered pairwise tuples across all slices. Always positive on the fast path.
    private(set) var totalRemaining: Int
    private var rowCount: Int

    /// Creates a balanced covering array generator for pairwise coverage.
    ///
    /// Values above ``maxDomainSize`` are clamped to prevent excessive memory allocation in pairwise bit vectors. When any clamped domain exceeds ``greedyThreshold``, the generator uses a deterministic spread instead of greedy pairwise optimization.
    ///
    /// - Parameter domainSizes: The number of distinct values for each parameter, in original order.
    package init(domainSizes: [UInt64]) {
        paramCount = domainSizes.count
        let perParamCap = Self.maxDomainSize / max(paramCount, 1)
        self.domainSizes = domainSizes.map { min(Int($0), perParamCap) }

        let maxDomain = self.domainSizes.max() ?? 0
        useGreedy = maxDomain <= Self.greedyThreshold

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
            totalRemaining = 1
            rowCount = 0
            return
        }
        spreadStrides = []

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
                    rowUncovered: [Int](repeating: sizeB, count: sizeA),
                    columnUncovered: [Int](repeating: sizeA, count: sizeB),
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
        }
    }

    // MARK: - Greedy Fill

    private func nextGreedy() -> CoveringArrayRow {
        var row = [UInt64](repeating: 0, count: paramCount)
        var filled = [Bool](repeating: false, count: paramCount)
        let startParam = rowCount % paramCount

        for _ in 0 ..< paramCount {
            var bestParam = -1
            var bestValue = 0
            var bestGain = -1.0

            for offset in 0 ..< paramCount {
                let param = (startParam &+ offset) % paramCount
                guard filled[param] == false else { continue }

                for value in 0 ..< domainSizes[param] {
                    let gain = computeGain(
                        param: param,
                        value: value,
                        row: row,
                        filled: filled
                    )
                    if gain > bestGain {
                        bestGain = gain
                        bestParam = param
                        bestValue = value
                    }
                }
            }

            guard bestParam >= 0 else { break }
            row[bestParam] = UInt64(bestValue)
            filled[bestParam] = true
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

    /// Computes the coverage gain for assigning `value` to `param`, given the partially filled row.
    ///
    /// For each pairwise slice involving `param`: if the other parameter is already filled, the gain is exact (1 if the pair is uncovered, 0 otherwise). If the other parameter is unfilled, the gain is the precomputed marginal uncovered count divided by the other parameter's domain size — matching Bryce and Colbourn's unrestricted density weighting without iterating the domain.
    private func computeGain(
        param: Int,
        value: Int,
        row: [UInt64],
        filled: [Bool]
    ) -> Double {
        var gain = 0.0

        for sliceIndex in slicesByParam[param] {
            let slice = slices[sliceIndex]

            if slice.paramA == param {
                if filled[slice.paramB] {
                    let index = UInt32(value &* slice.domainB &+ Int(row[slice.paramB]))
                    if slice.bits.isSet(index) == false {
                        gain += 1
                    }
                } else {
                    gain += Double(slice.rowUncovered[value]) / Double(slice.domainB)
                }
            } else {
                if filled[slice.paramA] {
                    let index = UInt32(Int(row[slice.paramA]) &* slice.domainB &+ value)
                    if slice.bits.isSet(index) == false {
                        gain += 1
                    }
                } else {
                    gain += Double(slice.columnUncovered[value]) / Double(slice.domainA)
                }
            }
        }

        return gain
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

// MARK: - Pairwise Slice

/// Tracks pairwise coverage for one (paramA, paramB) combination.
private struct PairwiseSlice {
    let paramA: Int
    let paramB: Int
    let domainA: Int
    let domainB: Int

    /// Bit vector indexed as `valueA * domainB + valueB`. A set bit means the pair is covered.
    var bits: BalancedBitVector

    /// `rowUncovered[a]` is the number of uncovered tuples in row `a` (how many values of paramB have not been paired with `a`).
    var rowUncovered: [Int]

    /// `columnUncovered[b]` is the number of uncovered tuples in column `b` (how many values of paramA have not been paired with `b`).
    var columnUncovered: [Int]

    var remaining: Int
}
