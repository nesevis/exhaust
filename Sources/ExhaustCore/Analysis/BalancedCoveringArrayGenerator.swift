// MARK: - Academic Background

// Density-based pairwise covering array generator with dynamic factor ordering.
//
// The standard Density (Bryce & Colbourn, 2009) algorithm fills columns left-to-right in a fixed order. This starves later parameters under partial budgets: with three parameters with equal domains at budget 200, the first two reach 100% value coverage while the third sits at 5%.
//
// This generator addresses the starvation by choosing which parameter to fill next based on the density signal itself: the parameter whose best candidate covers the most new pairs goes first. When multiple parameters have equal gain (common with equal-sized domains), a cycled start offset rotates which parameter wins the tie, ensuring each parameter gets equal opportunity to be filled first across successive rows.
//
// The coverage state is shared across all rows: each row's greedy choices see every pair covered by prior rows, so no effort is wasted on duplicates.

// MARK: - Per-Slice Tracking

// Whether a slice is tracked is decided slice by slice, not for the generator as a whole. Greedy fill evaluates every candidate value for every unfilled parameter per row: O(params x domain x slices). For a narrow slice this is fast and produces a near-optimal covering array that exhausts all pairs early. For a wide slice the pair space (dA x dB) dwarfs any practical budget, so greedy optimization spends its time distinguishing between negligible coverage fractions. At domain 64 the pairwise space is 4,096 per slice; a typical budget of 200 covers ~5%, the point where adaptive selection stops outperforming uniform spread.
//
// A slice with dA x dB at or below the slice threshold is tracked: it allocates a bit vector and contributes to greedy gains. A slice above it is never constructed. A parameter left with no tracked slice takes its value from the spread instead, so one wide parameter no longer costs pairwise coverage on the narrow slices around it.
//
// The spread is deterministic: coprime stride cycling plus a per-lap SplitMix64 phase offset, O(1) per parameter with no bit vectors and no coverage tracking. Each parameter cycles through all domain values (the coprime stride guarantees full value coverage per lap), and the lap offset re-phases it every time it completes a lap. The offset is what makes pair coverage converge: bare stride cycling revisits the same lcm(d1, d2) pairs forever, so two parameters whose domain sizes share a factor never exceed 1/gcd(d1, d2) pair coverage. Uniform but not adaptive: the spread may revisit covered pairs while others remain uncovered.
//
// Termination follows the partition. All slices tracked means the generator stops once every pair is covered, which is what callers that need a finite stream rely on. Any untracked slice means the stream never ends, because the spread reports no exhaustion.

/// Pairwise covering array generator with dynamic factor ordering for balanced parameter coverage.
///
/// Emits one row at a time via ``next()``, greedily selecting values to maximize new pairwise coverage. The fill order is not fixed: each step picks the (parameter, value) pair with the highest gain across all unfilled parameters. A cycled start offset breaks ties so that each parameter takes turns in the favored position.
///
/// Slices whose pair space exceeds the square of ``greedyThreshold`` are not tracked, and a parameter with no tracked slice is filled by a deterministic stride spread instead. A generator whose slices are all tracked behaves exactly as a greedy one; a generator with none behaves exactly as a spread.
///
/// - Important: ``next()`` returns `nil` only when every slice is tracked and every pair is covered. With any untracked slice the stream is infinite, and the caller bounds it.
/// - Note: Supports strength 2 (pairwise) only. For exhaustive coverage at higher strengths, use ``PullBasedCoveringArrayGenerator``.
/// - Note: Needs at least two parameters. With one parameter there are no pairs to cover, so the stream is empty.
package final class BalancedCoveringArrayGenerator {
    /// Per-parameter domain sizes are clamped to this value divided by the parameter count.
    ///
    /// Slice tracking already bounds each bit vector to the slice threshold, so at the default threshold this clamp only truncates the value space a parameter can emit. It bounds allocation for a caller that raises the threshold far enough to track every slice.
    package static let maxDomainSize = 16384

    /// Slices whose pair space exceeds the square of this threshold are left untracked, and parameters with no tracked slice fall back to the deterministic spread.
    package static let greedyThreshold = 64

    /// Tolerance on the ceiling comparison that ends a candidate scan early.
    ///
    /// Gains accumulate as `Double(uncovered) * (1 / Double(domain))`, and that product is not exactly 1.0 for every domain size (49 is the smallest case, giving 0.99999999999999989), so an exact comparison against the ceiling silently stops firing for those domains. A gain genuinely below the ceiling is short by at least one uncovered tuple's worth, `1 / domain`, which is orders of magnitude above the accumulated rounding error this absorbs.
    private static let ceilingTolerance = 1e-9

    /// Seeds the value scan's starting offset in the greedy fill and the lap offset in the spread.
    ///
    /// In the greedy fill, the first pick of every row saturates the gain ceiling, so `break search` takes whichever value it scans first. Scanning from a derived offset instead of always from zero picks an equally optimal value in a different place, which is what stops successive rows filling shells outward from the origin.
    ///
    /// In the spread, the seed joins the per-lap offset derivation, so a truncated run's row prefix varies per seed rather than testing the same leading points every run.
    ///
    /// Zero disables the greedy scan offset, reproducing the unseeded scan order exactly. The spread always applies its lap offset, and a zero seed reproduces the unseeded derivation.
    private let seed: UInt64

    private let paramCount: Int
    private let domainSizes: [Int]
    /// Strides for the spread, one per parameter. Only read for parameters with no tracked slice.
    private let spreadStrides: [Int]
    /// Tracked slices only. A slice above the threshold is never constructed, so nothing here needs an is-tracked test.
    private var slices: [PairwiseSlice]
    private let slicesByParam: [[Int]]
    /// Parameters with at least one tracked slice, in ascending order. The greedy fill iterates this; every other parameter is filled by the spread before the fill starts.
    private let greedyParams: [Int]
    /// True when at least one slice was left untracked, which is what makes the row stream infinite.
    private let hasUntrackedSlices: Bool
    /// Scratch buffer for per-value gains during greedy fill, sized to the largest greedy parameter's domain. Reused across rows to avoid per-row allocation.
    private let gainScratch: UnsafeMutablePointer<Double>
    /// Total number of uncovered pairwise tuples across all tracked slices.
    private(set) var totalRemaining: Int
    private var rowCount: Int

    /// Creates a balanced covering array generator for pairwise coverage.
    ///
    /// Values above ``maxDomainSize`` are clamped to prevent excessive memory allocation in pairwise bit vectors. Each slice is then tracked or not on its own: a slice whose pair space exceeds `greedyThreshold` squared is left untracked, and any parameter with no tracked slice is filled by a deterministic spread.
    ///
    /// - Parameters:
    ///   - domainSizes: The number of distinct values for each parameter, in original order. Every entry must be at least 1.
    ///   - seed: Rotates the greedy scan offset and the spread's lap offset. Zero reproduces the unseeded array.
    ///   - greedyThreshold: The largest domain still worth tracking. Its square is the per-slice pair space above which a slice goes untracked. Defaults to ``greedyThreshold``. Pass the largest domain present to track every slice, which is what a caller needing a terminating stream must do.
    package init(domainSizes: [UInt64], seed: UInt64 = 0, greedyThreshold: Int? = nil) {
        precondition(
            domainSizes.allSatisfy { $0 >= 1 },
            "A covering array parameter needs at least one value; an empty domain has no row to emit."
        )
        self.seed = seed
        let effectiveThreshold = greedyThreshold ?? Self.greedyThreshold
        let (squared, overflow) = effectiveThreshold.multipliedReportingOverflow(by: effectiveThreshold)
        let sliceThreshold = overflow ? Int.max : squared
        paramCount = domainSizes.count
        let perParamCap = Self.maxDomainSize / max(paramCount, 1)
        let clamped = domainSizes.map { min(Int($0), perParamCap) }
        self.domainSizes = clamped

        spreadStrides = clamped.enumerated().map { param, domain in
            var stride = 2 &* param &+ 1
            while Self.gcd(stride, domain) != 1 {
                stride &+= 2
            }
            return stride
        }

        var allSlices: [PairwiseSlice] = []
        allSlices.reserveCapacity(clamped.count * (clamped.count - 1) / 2)
        var total = 0
        var anyUntracked = false

        for first in 0 ..< clamped.count {
            for second in (first + 1) ..< clamped.count {
                let sizeA = clamped[first]
                let sizeB = clamped[second]
                let tupleCount = sizeA * sizeB
                guard tupleCount <= sliceThreshold else {
                    anyUntracked = true
                    continue
                }
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
        hasUntrackedSlices = anyUntracked

        var byParam = [[Int]](repeating: [], count: clamped.count)
        for (index, slice) in allSlices.enumerated() {
            byParam[slice.paramA].append(index)
            byParam[slice.paramB].append(index)
        }
        slicesByParam = byParam
        let greedy = (0 ..< clamped.count).filter { byParam[$0].isEmpty == false }
        greedyParams = greedy

        let widestGreedyDomain = greedy.map { clamped[$0] }.max() ?? 0
        gainScratch = .allocate(capacity: max(widestGreedyDomain, 1))
        gainScratch.initialize(repeating: 0, count: max(widestGreedyDomain, 1))

        totalRemaining = total
        rowCount = 0
    }

    /// Returns the next row, or `nil` once every tracked pair is covered and no untracked slice remains.
    ///
    /// A generator holding any untracked slice never returns `nil`: the spread that fills those parameters reports no exhaustion, and stopping on the tracked pairs alone would cut the stream short while the untracked parameters were still cycling usefully.
    package func next() -> CoveringArrayRow? {
        if totalRemaining == 0, hasUntrackedSlices == false {
            return nil
        }
        return nextRow()
    }

    deinit {
        for index in 0 ..< slices.count {
            slices[index].bits.deallocate()
            slices[index].rowUncovered.deallocate()
            slices[index].columnUncovered.deallocate()
        }
        gainScratch.deallocate()
    }

    // MARK: - Row Fill

    /// Builds one row: the spread fills every parameter with no tracked slice, then the greedy fill takes the rest.
    ///
    /// Spread values do not depend on coverage state, so computing them first costs the greedy fill nothing. Their parameters are marked filled purely to keep them out of the scan, and no gain reads them: a spread parameter has no tracked slice, so it appears in no gain sum.
    private func nextRow() -> CoveringArrayRow {
        var row = [UInt64](repeating: 0, count: paramCount)
        var filled = [Bool](repeating: false, count: paramCount)
        let startParam = rowCount % paramCount

        for param in 0 ..< paramCount where slicesByParam[param].isEmpty {
            row[param] = spreadValue(param: param)
            filled[param] = true
        }

        slices.withUnsafeBufferPointer { sliceBuffer in
            for _ in 0 ..< greedyParams.count {
                // Each tracked slice contributes at most 1 to a candidate's gain, so no candidate can exceed the number of tracked slices its parameter participates in. Ties never replace an earlier best, so scanning can stop as soon as a candidate reaches the highest ceiling any still-unfilled parameter could reach: the selected (parameter, value) is identical to a full scan.
                var maxPossibleGain = 0.0
                for param in greedyParams where filled[param] == false {
                    maxPossibleGain = max(maxPossibleGain, Double(slicesByParam[param].count))
                }
                let exitThreshold = maxPossibleGain - Self.ceilingTolerance

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

                    let valueOffset = seed == 0
                        ? 0
                        : Int(
                            Xoshiro256.deriveSeed(from: seed, at: Self.rotationIndex(step: rowCount, param: param))
                                % UInt64(domain)
                        )
                    // Two contiguous passes rather than one wrapping scan: each pass is a plain monotone loop the optimizer can unroll, where a per-step wrap or modulo costs ~20% on large domains. An unseeded generator's first pass is exactly the full scan, and its second is empty.
                    for rangeIndex in 0 ..< 2 {
                        let range = rangeIndex == 0 ? valueOffset ..< domain : 0 ..< valueOffset
                        for value in range {
                            let gain = gainScratch[value]
                            if gain > bestGain {
                                bestGain = gain
                                bestParam = param
                                bestValue = value
                                if gain >= exitThreshold { break search }
                            }
                        }
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

    /// Returns a parameter's spread value for the current row.
    ///
    /// The lap offset is constant within a lap, so each parameter still sweeps its full domain every `domain` rows, and varies across laps to break the joint period: without it, any parameter pair repeats with period lcm(d1, d2), capping pair coverage at 1/gcd(d1, d2) regardless of budget.
    private func spreadValue(param: Int) -> UInt64 {
        let domain = domainSizes[param]
        let lap = rowCount / domain
        let index = Self.rotationIndex(step: lap, param: param)
        let lapOffset = Int(Xoshiro256.deriveSeed(from: seed, at: index) % UInt64(domain))
        return UInt64((rowCount &* spreadStrides[param] &+ param &+ lapOffset) % domain)
    }

    /// Packs a step (a lap in the spread, a row in the greedy fill) and a parameter into one derivation index.
    ///
    /// Both offsets reach ``Xoshiro256/deriveSeed(from:at:)`` through its index argument rather than being folded into the base seed. Adding them to the seed instead makes seed *s* + 1 at lap *k* draw exactly seed *s*'s offset at lap *k* + 1: with equal domain sizes every parameter shares lap boundaries and a full lap advances the row value by `stride * domain`, which is zero modulo the domain, so consecutive seeds emit the same row stream one lap apart. Ten consecutive seeds at budget 200 and domain 100 then cover 1,100 distinct rows where ten independent rotations cover 2,000.
    private static func rotationIndex(step: Int, param: Int) -> UInt64 {
        (UInt64(bitPattern: Int64(step)) &<< 32) | (UInt64(bitPattern: Int64(param)) & 0xFFFF_FFFF)
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
