// MARK: - Academic Background

// Density-based pairwise covering array generator with dynamic factor ordering.
//
// The standard Density (Bryce & Colbourn, 2009) algorithm fills columns left-to-right in a fixed order. This starves later parameters under partial budgets: with three parameters with equal domains at budget 200, the first two reach 100% value coverage while the third sits at 5%.
//
// This generator addresses the starvation by choosing which parameter to fill next based on the density signal itself: the parameter whose best candidate covers the most new pairs goes first. When multiple parameters have equal gain (common with equal-sized domains), a cycled start offset rotates which parameter wins the tie, ensuring each parameter gets equal opportunity to be filled first across successive rows.
//
// The coverage state is shared across all rows: each row's greedy choices see every pair covered by prior rows, so no effort is wasted on duplicates.

/// Pairwise covering array generator with dynamic factor ordering for balanced parameter coverage.
///
/// Emits one row at a time via ``next()``, greedily selecting values to maximize new pairwise coverage. The fill order is not fixed: each step picks the (parameter, value) pair with the highest gain across all unfilled parameters. A cycled start offset breaks ties so that each parameter takes turns in the favored position.
///
/// Supports strength 2 (pairwise) only. For exhaustive coverage at higher strengths, use ``PullBasedCoveringArrayGenerator``.
package final class BalancedCoveringArrayGenerator {
    private let paramCount: Int
    private let domainSizes: [Int]
    private var slices: [PairwiseSlice]
    private let slicesByParam: [[Int]]
    /// Total number of uncovered pairwise tuples across all slices.
    private(set) var totalRemaining: Int
    private var rowCount: Int

    /// Creates a balanced covering array generator for pairwise coverage.
    ///
    /// - Parameter domainSizes: The number of distinct values for each parameter, in original order.
    package init(domainSizes: [UInt64]) {
        paramCount = domainSizes.count
        self.domainSizes = domainSizes.map { Int($0) }

        var allSlices: [PairwiseSlice] = []
        allSlices.reserveCapacity(domainSizes.count * (domainSizes.count - 1) / 2)
        var total = 0

        for first in 0 ..< domainSizes.count {
            for second in (first + 1) ..< domainSizes.count {
                let sizeA = Int(domainSizes[first])
                let sizeB = Int(domainSizes[second])
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

        var byParam = [[Int]](repeating: [], count: domainSizes.count)
        for (index, slice) in allSlices.enumerated() {
            byParam[slice.paramA].append(index)
            byParam[slice.paramB].append(index)
        }
        slicesByParam = byParam
        totalRemaining = total
        rowCount = 0
    }

    /// Returns the next row that greedily maximizes new pairwise coverage, or `nil` if all pairs are covered.
    package func next() -> CoveringArrayRow? {
        if totalRemaining == 0 { return nil }

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

    deinit {
        for index in 0 ..< slices.count {
            slices[index].bits.deallocate()
        }
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
