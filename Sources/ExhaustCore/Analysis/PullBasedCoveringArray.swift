//
//  PullBasedCoveringArray.swift
//  Exhaust
//

// MARK: - Academic Provenance

//
// This file implements the "density method" — a one-test-at-a-time greedy
// covering array generator — from:
//
//   Bryce, R.C. & Colbourn, C.J. (2009). "A density-based greedy algorithm
//   for higher strength covering arrays." Softw. Test. Verif. Reliab.,
//   19(1), 37–53. DOI: 10.1002/stvr.393
//
// The paper defines a four-layer framework for greedy covering array
// construction: (1) test suite repetitions, (2) multiple candidates per row,
// (3) factor ordering, and (4) level selection via density. Exhaust
// instantiates this framework with the following choices:
//
// Layer 1 — Repetitions: 1 (deterministic, no randomness). The paper shows
//   that more repetitions reduce array size, but Exhaust stops on first
//   property failure so minimizing total array size is secondary to fast
//   time-to-first-row.
//
// Layer 2 — Multiple candidates: 1 candidate per row. The paper's Table V
//   shows 10 candidates can reduce array size by ~5–10%, but at 10x the
//   per-row cost. Not worthwhile for early-stop property-based testing.
//
// Layer 3 — Factor ordering: Fixed left-to-right after sorting parameters
//   by domain size ascending (smallest first). This is a static heuristic,
//   not the paper's density-driven ordering. The paper finds density-based
//   ordering produces modestly smaller arrays, but the effect diminishes
//   with unrestricted density (Section 3, p. 47).
//
// Layer 4 — Level selection: Unrestricted density (Section 2, Theorem 2.2).
//   For completing slices (all other factors fixed), the contribution is
//   exact: 1 if the tuple is uncovered, 0 otherwise. For non-completing
//   slices (some factors still free), the contribution is the count of
//   compatible uncovered tuples divided by the product of unfilled domain
//   sizes — matching the paper's 1/|V_f| weighting. This preserves the
//   O(log k) row-count guarantee from Theorem 2.2.
//
// The slicesByCompletingColumn optimization (only evaluate completing slices
// at each column) is augmented with partialSlicesByColumn for non-completing
// slices. The completing evaluation is the 0-restricted case; the partial
// evaluation adds the unrestricted density signal from free factors.
//
// What Exhaust does NOT implement from the paper:
//   - Best (t-1)-tuple seeding (Section 3): fixing the first t-1 factors to
//     the values of the most common uncovered (t-1)-tuple before density fill.
//   - Density-driven factor ordering (Section 3): choosing the factor with
//     highest factor density at each step instead of a fixed left-to-right order.
//   - Multiple candidates or repetitions (Layers 1–2).
//   - Seeding from an existing array (Section 4, p. 52): pre-marking tuples
//     from a seed array (for example, an orthogonal array) before generating
//     additional rows.
//
// These omissions are deliberate: Exhaust's use case is property-based testing
// where the first failure matters more than the total array size, and
// determinism (no random tie-breaking) is required for reproducibility.

// MARK: - Pull-Based Bit Vector

/// Bit-vector with unsafe pointer storage for coverage tracking.
private struct PullBitVector {
    private let storage: UnsafeMutablePointer<UInt64>
    let wordCount: Int

    init(bitCount: Int) {
        let words = max((bitCount &+ 63) >> 6, 1)
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

    /// Counts unset bits in the range [`start`, `start` + `count`).
    @inline(__always)
    func countUnsetInRange(from start: UInt32, count: Int) -> Int {
        if count == 0 { return 0 }
        var unset = 0
        let end = start &+ UInt32(count)
        let firstWord = Int(start &>> 6)
        let lastWord = Int((end &- 1) &>> 6)
        let firstBit = start & 63
        let lastBit = (end &- 1) & 63

        if firstWord == lastWord {
            // Single word: mask from firstBit to lastBit inclusive.
            let mask = (UInt64.max &<< firstBit) & (UInt64.max &>> (63 &- lastBit))
            unset = (~storage[firstWord] & mask).nonzeroBitCount
        } else {
            // First partial word.
            let firstMask = UInt64.max &<< firstBit
            unset = (~storage[firstWord] & firstMask).nonzeroBitCount

            // Full words in between.
            var word = firstWord &+ 1
            while word < lastWord {
                unset &+= (~storage[word]).nonzeroBitCount
                word &+= 1
            }

            // Last partial word.
            let lastMask = UInt64.max &>> (63 &- lastBit)
            unset &+= (~storage[lastWord] & lastMask).nonzeroBitCount
        }
        return unset
    }

    func deallocate() {
        storage.deinitialize(count: wordCount)
        storage.deallocate()
    }
}

// MARK: - Partial Slice Reference

/// Reference to a non-completing slice at a specific column, storing the column's position within the slice and the stride at that position (which equals the range size for partial coverage counting).
private struct PartialSliceRef {
    let sliceIndex: Int

    /// Which position (0-indexed) this column occupies in the slice's paramIndices.
    let position: UInt8

    /// The stride at this position — equals the product of domain sizes for all positions after this one. Used as the range count for ``PullBitVector/countUnsetInRange(from:count:)``.
    let rangeSize: UInt32
}

// MARK: - Pull-Based Coverage Slice

/// Tracks coverage for one specific t-tuple of parameter indices.
///
/// Unlike the FIPOG ``CoverageSlice`` (which stores only `t-1` partner params because the new parameter is implicit), this stores all `t` parameter indices because any slice can be evaluated at any column fill step.
private struct PullCoverageSlice {
    var bits: PullBitVector
    let strides: (UInt32, UInt32, UInt32, UInt32)

    /// All t parameter indices (in reordered space, sorted ascending). Only the first `strength` entries are meaningful.
    let paramIndices: (UInt16, UInt16, UInt16, UInt16)

    var remaining: Int

    @inline(__always)
    func flatIndex2(_ value0: UInt16, _ value1: UInt16) -> UInt32 {
        UInt32(value0) &* strides.0 &+ UInt32(value1)
    }

    @inline(__always)
    func flatIndex3(_ value0: UInt16, _ value1: UInt16, _ value2: UInt16) -> UInt32 {
        UInt32(value0) &* strides.0 &+ UInt32(value1) &* strides.1 &+ UInt32(value2)
    }

    @inline(__always)
    func flatIndex4(
        _ value0: UInt16,
        _ value1: UInt16,
        _ value2: UInt16,
        _ value3: UInt16
    ) -> UInt32 {
        UInt32(value0) &* strides.0
            &+ UInt32(value1) &* strides.1
            &+ UInt32(value2) &* strides.2
            &+ UInt32(value3)
    }

    @inline(__always)
    mutating func mark(_ index: UInt32) -> Bool {
        if bits.set(index) {
            remaining &-= 1
            return true
        }
        return false
    }

    @inline(__always)
    func isSet(_ index: UInt32) -> Bool {
        bits.isSet(index)
    }

    mutating func deallocate() {
        bits.deallocate()
    }
}

// MARK: - Parameter Ordering

/// Reorders parameters so that smallest domains come first.
///
/// Early columns (small domain) have fewer completing slices and fewer candidate values, so they resolve quickly. Later columns (larger domain) have the most completing slices and the richest greedy signal.
private struct ParameterOrdering {
    let reorderedDomainSizes: ContiguousArray<UInt16>

    /// Maps reordered index back to original parameter index.
    let inversePermutation: ContiguousArray<Int>

    init(domainSizes: ContiguousArray<UInt16>) {
        let indexed = domainSizes.enumerated().sorted { $0.element < $1.element }
        var reordered = ContiguousArray<UInt16>()
        var inverse = ContiguousArray<Int>()
        reordered.reserveCapacity(domainSizes.count)
        inverse.reserveCapacity(domainSizes.count)
        var index = 0
        while index < indexed.count {
            reordered.append(indexed[index].element)
            inverse.append(indexed[index].offset)
            index &+= 1
        }
        reorderedDomainSizes = reordered
        inversePermutation = inverse
    }

    /// Restores a row from reordered space to original parameter order.
    func restore(_ row: ContiguousArray<UInt16>) -> [UInt64] {
        let count = row.count
        var output = [UInt64](repeating: 0, count: count)
        var index = 0
        while index < count {
            output[inversePermutation[index]] = UInt64(row[index])
            index &+= 1
        }
        return output
    }
}

// MARK: - Pull-Based Covering Array Generator

/// Pull-based covering array generator that emits one row at a time via ``next()``.
///
/// Uses a one-row-at-a-time greedy algorithm with left-to-right column fill (Bryce & Colbourn, 2007/2009). All C(k, t) coverage slices are allocated once at initialization. Each ``next()`` call fills a row column-by-column, evaluating only slices whose rightmost parameter equals the current column. The caller pulls rows until a property test fails or coverage is exhausted.
///
/// The interaction strength is fixed at initialization and supports values 2, 3, or 4. It does not escalate during generation — all rows target the same strength throughout the generator's lifetime.
///
/// Parameters are reordered internally so that smallest domains come first. This means early columns have fewer completing slices and fewer candidate values, resolving quickly. Later columns have the most completing slices and the richest greedy signal. Rows are restored to the original parameter order before being returned.
public struct PullBasedCoveringArrayGenerator {
    private let strength: Int
    private let paramCount: Int
    private let ordering: ParameterOrdering
    private var slices: ContiguousArray<PullCoverageSlice>

    /// `slicesByColumn[c]` contains the indices of slices whose rightmost parameter is `c`. When filling column `c`, only these slices can have tuples that become fully determined.
    private let slicesByColumn: ContiguousArray<ContiguousArray<Int>>

    /// `partialSlicesByColumn[c]` contains references to slices that include column `c` but do NOT complete at `c`. Used to evaluate partial coverage potential at early columns (0 through `strength` - 2) that have no completing slices.
    private let partialSlicesByColumn: ContiguousArray<ContiguousArray<PartialSliceRef>>

    /// Total number of uncovered tuples across all slices.
    public private(set) var totalRemaining: Int

    /// Reused buffer for row construction in reordered parameter space.
    private var rowBuffer: ContiguousArray<UInt16>

    /// Creates a pull-based covering array generator.
    ///
    /// - Parameters:
    ///   - domainSizes: The domain size for each parameter, in original order.
    ///   - strength: The interaction strength t (2, 3, or 4).
    public init(domainSizes: [UInt64], strength: Int) {
        precondition(strength >= 2 && strength <= 4)
        precondition(domainSizes.count >= strength)

        self.strength = strength
        paramCount = domainSizes.count

        let rawDomains = ContiguousArray(domainSizes.map { UInt16(clamping: $0) })
        ordering = ParameterOrdering(domainSizes: rawDomains)

        var allSlices = ContiguousArray<PullCoverageSlice>()
        var byColumn = ContiguousArray<ContiguousArray<Int>>(
            repeating: ContiguousArray<Int>(),
            count: domainSizes.count
        )
        var total = 0
        let domains = ordering.reorderedDomainSizes

        switch strength {
        case 2:
            allSlices.reserveCapacity(domainSizes.count * (domainSizes.count - 1) / 2)
            var first = 0
            while first < domainSizes.count {
                var second = first &+ 1
                while second < domainSizes.count {
                    let d0 = UInt32(domains[first])
                    let d1 = UInt32(domains[second])
                    let tupleCount = Int(d0) * Int(d1)
                    allSlices.append(PullCoverageSlice(
                        bits: PullBitVector(bitCount: tupleCount),
                        strides: (d1, 1, 0, 0),
                        paramIndices: (UInt16(first), UInt16(second), 0, 0),
                        remaining: tupleCount
                    ))
                    byColumn[second].append(allSlices.count &- 1)
                    total &+= tupleCount
                    second &+= 1
                }
                first &+= 1
            }

        case 3:
            allSlices.reserveCapacity(
                domainSizes.count * (domainSizes.count - 1) * (domainSizes.count - 2) / 6
            )
            var first = 0
            while first < domainSizes.count {
                var second = first &+ 1
                while second < domainSizes.count {
                    var third = second &+ 1
                    while third < domainSizes.count {
                        let d0 = UInt32(domains[first])
                        let d1 = UInt32(domains[second])
                        let d2 = UInt32(domains[third])
                        let tupleCount = Int(d0) * Int(d1) * Int(d2)
                        let s0 = d1 &* d2
                        allSlices.append(PullCoverageSlice(
                            bits: PullBitVector(bitCount: tupleCount),
                            strides: (s0, d2, 1, 0),
                            paramIndices: (UInt16(first), UInt16(second), UInt16(third), 0),
                            remaining: tupleCount
                        ))
                        byColumn[third].append(allSlices.count &- 1)
                        total &+= tupleCount
                        third &+= 1
                    }
                    second &+= 1
                }
                first &+= 1
            }

        case 4:
            allSlices.reserveCapacity(
                domainSizes.count * (domainSizes.count - 1)
                    * (domainSizes.count - 2) * (domainSizes.count - 3) / 24
            )
            var first = 0
            while first < domainSizes.count {
                var second = first &+ 1
                while second < domainSizes.count {
                    var third = second &+ 1
                    while third < domainSizes.count {
                        var fourth = third &+ 1
                        while fourth < domainSizes.count {
                            let d0 = UInt32(domains[first])
                            let d1 = UInt32(domains[second])
                            let d2 = UInt32(domains[third])
                            let d3 = UInt32(domains[fourth])
                            let tupleCount = Int(d0) * Int(d1) * Int(d2) * Int(d3)
                            let s0 = d1 &* d2 &* d3
                            let s1 = d2 &* d3
                            allSlices.append(PullCoverageSlice(
                                bits: PullBitVector(bitCount: tupleCount),
                                strides: (s0, s1, d3, 1),
                                paramIndices: (
                                    UInt16(first), UInt16(second),
                                    UInt16(third), UInt16(fourth)
                                ),
                                remaining: tupleCount
                            ))
                            byColumn[fourth].append(allSlices.count &- 1)
                            total &+= tupleCount
                            fourth &+= 1
                        }
                        third &+= 1
                    }
                    second &+= 1
                }
                first &+= 1
            }

        default:
            break
        }

        // Build partial (non-completing) slice references for early columns.
        // For each slice, every param except the rightmost is a non-completing participant.
        var partialByColumn = ContiguousArray<ContiguousArray<PartialSliceRef>>(
            repeating: ContiguousArray<PartialSliceRef>(),
            count: domainSizes.count
        )
        var sliceIdx = 0
        while sliceIdx < allSlices.count {
            let slice = allSlices[sliceIdx]
            // For t=2: position 0 is non-completing (position 1 is rightmost/completing).
            // For t=3: positions 0 and 1 are non-completing.
            // For t=4: positions 0, 1, and 2 are non-completing.
            let params = slice.paramIndices
            let strides = slice.strides
            if strength >= 2 {
                partialByColumn[Int(params.0)].append(PartialSliceRef(
                    sliceIndex: sliceIdx, position: 0, rangeSize: strides.0
                ))
            }
            if strength >= 3 {
                partialByColumn[Int(params.1)].append(PartialSliceRef(
                    sliceIndex: sliceIdx, position: 1, rangeSize: strides.1
                ))
            }
            if strength >= 4 {
                partialByColumn[Int(params.2)].append(PartialSliceRef(
                    sliceIndex: sliceIdx, position: 2, rangeSize: strides.2
                ))
            }
            sliceIdx &+= 1
        }

        slices = allSlices
        slicesByColumn = byColumn
        partialSlicesByColumn = partialByColumn
        totalRemaining = total
        rowBuffer = ContiguousArray<UInt16>(repeating: 0, count: domainSizes.count)
    }

    /// Returns the next row that greedily maximises new t-tuple coverage, or `nil` if all t-tuples are already covered.
    public mutating func next() -> CoveringArrayRow? {
        if totalRemaining == 0 { return nil }

        switch strength {
        case 2: fillRow2()
        case 3: fillRow3()
        case 4: fillRow4()
        default: return nil
        }

        markCoverage()

        return CoveringArrayRow(values: ordering.restore(rowBuffer))
    }

    /// Deallocates all coverage slice bit vectors. Must be called when the generator is no longer needed.
    public mutating func deallocate() {
        var index = 0
        while index < slices.count {
            slices[index].deallocate()
            index &+= 1
        }
    }

    // MARK: - Partial Coverage Evaluation

    /// Evaluates partial coverage density for a candidate value across non-completing slices.
    ///
    /// Each non-completing slice's contribution is the count of compatible uncovered tuples divided by the range size (the product of unfilled domain sizes). This matches Bryce & Colbourn's unrestricted density: free factors are weighted by 1/|V_f|, so the contribution represents the *probability* that a random assignment to the unfilled factors would cover an uncovered tuple.
    private func evaluatePartialCoverage(col: Int, candidate: UInt16) -> Double {
        let partialRefs = partialSlicesByColumn[col]
        let partialCount = partialRefs.count
        if partialCount == 0 { return 0 }

        var density = 0.0
        var refPos = 0
        while refPos < partialCount {
            let ref = partialRefs[refPos]
            let slice = slices[ref.sliceIndex]

            // Compute the base flat index from all filled positions before this column.
            var baseIdx: UInt32 = 0
            if ref.position >= 1 {
                baseIdx &+= UInt32(rowBuffer[Int(slice.paramIndices.0)]) &* slice.strides.0
            }
            if ref.position >= 2 {
                baseIdx &+= UInt32(rowBuffer[Int(slice.paramIndices.1)]) &* slice.strides.1
            }
            if ref.position >= 3 {
                baseIdx &+= UInt32(rowBuffer[Int(slice.paramIndices.2)]) &* slice.strides.2
            }

            let start = baseIdx &+ UInt32(candidate) &* ref.rangeSize
            let uncovered = slice.bits.countUnsetInRange(from: start, count: Int(ref.rangeSize))
            density += Double(uncovered) / Double(ref.rangeSize)
            refPos &+= 1
        }
        return density
    }

    // MARK: - Strength-Specialized Row Fill

    private mutating func fillRow2() {
        var col = 0
        while col < paramCount {
            let relevantSlices = slicesByColumn[col]
            let relevantCount = relevantSlices.count
            let domain = ordering.reorderedDomainSizes[col]
            var bestValue: UInt16 = 0
            var bestGain = -1.0

            var candidate: UInt16 = 0
            while candidate < domain {
                rowBuffer[col] = candidate
                var gain = 0.0

                // Exact gain from completing slices (tuples fully determined at this column).
                var slicePos = 0
                while slicePos < relevantCount {
                    let sliceIdx = relevantSlices[slicePos]
                    let slice = slices[sliceIdx]
                    let v0 = rowBuffer[Int(slice.paramIndices.0)]
                    let v1 = rowBuffer[Int(slice.paramIndices.1)]
                    let flatIdx = slice.flatIndex2(v0, v1)
                    if slice.isSet(flatIdx) == false {
                        gain += 1
                    }
                    slicePos &+= 1
                }

                // Density-weighted partial gain from non-completing slices.
                gain += evaluatePartialCoverage(col: col, candidate: candidate)

                if gain > bestGain {
                    bestGain = gain
                    bestValue = candidate
                }
                candidate &+= 1
            }

            rowBuffer[col] = bestValue
            col &+= 1
        }
    }

    private mutating func fillRow3() {
        var col = 0
        while col < paramCount {
            let relevantSlices = slicesByColumn[col]
            let relevantCount = relevantSlices.count
            let domain = ordering.reorderedDomainSizes[col]
            var bestValue: UInt16 = 0
            var bestGain = -1.0

            var candidate: UInt16 = 0
            while candidate < domain {
                rowBuffer[col] = candidate
                var gain = 0.0

                var slicePos = 0
                while slicePos < relevantCount {
                    let sliceIdx = relevantSlices[slicePos]
                    let slice = slices[sliceIdx]
                    let v0 = rowBuffer[Int(slice.paramIndices.0)]
                    let v1 = rowBuffer[Int(slice.paramIndices.1)]
                    let v2 = rowBuffer[Int(slice.paramIndices.2)]
                    let flatIdx = slice.flatIndex3(v0, v1, v2)
                    if slice.isSet(flatIdx) == false {
                        gain += 1
                    }
                    slicePos &+= 1
                }

                gain += evaluatePartialCoverage(col: col, candidate: candidate)

                if gain > bestGain {
                    bestGain = gain
                    bestValue = candidate
                }
                candidate &+= 1
            }

            rowBuffer[col] = bestValue
            col &+= 1
        }
    }

    private mutating func fillRow4() {
        var col = 0
        while col < paramCount {
            let relevantSlices = slicesByColumn[col]
            let relevantCount = relevantSlices.count
            let domain = ordering.reorderedDomainSizes[col]
            var bestValue: UInt16 = 0
            var bestGain = -1.0

            var candidate: UInt16 = 0
            while candidate < domain {
                rowBuffer[col] = candidate
                var gain = 0.0

                var slicePos = 0
                while slicePos < relevantCount {
                    let sliceIdx = relevantSlices[slicePos]
                    let slice = slices[sliceIdx]
                    let v0 = rowBuffer[Int(slice.paramIndices.0)]
                    let v1 = rowBuffer[Int(slice.paramIndices.1)]
                    let v2 = rowBuffer[Int(slice.paramIndices.2)]
                    let v3 = rowBuffer[Int(slice.paramIndices.3)]
                    let flatIdx = slice.flatIndex4(v0, v1, v2, v3)
                    if slice.isSet(flatIdx) == false {
                        gain += 1
                    }
                    slicePos &+= 1
                }

                gain += evaluatePartialCoverage(col: col, candidate: candidate)

                if gain > bestGain {
                    bestGain = gain
                    bestValue = candidate
                }
                candidate &+= 1
            }

            rowBuffer[col] = bestValue
            col &+= 1
        }
    }

    // MARK: - Coverage Marking

    /// Marks all tuples covered by the current row across all slices.
    private mutating func markCoverage() {
        var col = 0
        while col < paramCount {
            let relevantSlices = slicesByColumn[col]
            let relevantCount = relevantSlices.count

            var slicePos = 0
            while slicePos < relevantCount {
                let sliceIdx = relevantSlices[slicePos]
                let flatIdx: UInt32
                switch strength {
                case 2:
                    flatIdx = slices[sliceIdx].flatIndex2(
                        rowBuffer[Int(slices[sliceIdx].paramIndices.0)],
                        rowBuffer[Int(slices[sliceIdx].paramIndices.1)]
                    )
                case 3:
                    flatIdx = slices[sliceIdx].flatIndex3(
                        rowBuffer[Int(slices[sliceIdx].paramIndices.0)],
                        rowBuffer[Int(slices[sliceIdx].paramIndices.1)],
                        rowBuffer[Int(slices[sliceIdx].paramIndices.2)]
                    )
                case 4:
                    flatIdx = slices[sliceIdx].flatIndex4(
                        rowBuffer[Int(slices[sliceIdx].paramIndices.0)],
                        rowBuffer[Int(slices[sliceIdx].paramIndices.1)],
                        rowBuffer[Int(slices[sliceIdx].paramIndices.2)],
                        rowBuffer[Int(slices[sliceIdx].paramIndices.3)]
                    )
                default:
                    slicePos &+= 1
                    continue
                }
                if slices[sliceIdx].mark(flatIdx) {
                    totalRemaining &-= 1
                }
                slicePos &+= 1
            }
            col &+= 1
        }
    }
}
