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
/// Generated using a FIPOG-style IPOG algorithm with bit-vector coverage tracking, column-major storage, and strength-specialized hot loops for t=2, 3, and 4 (Kleine & Simos, "An efficient design and implementation of the in-parameter-order algorithm", Math. Comput. Sci. 12(1), 2018). Rows are returned in shortlex order.
public struct CoveringArray: @unchecked Sendable {
    public let strength: Int
    public let rows: [CoveringArrayRow]
    public let profile: FiniteDomainProfile

    /// Returns the strongest covering array that fits within `budget` rows, or `nil` if even t=2 doesn't fit.
    ///
    /// Searches bottom-up (t=2, 3, …) so it can stop as soon as a strength exceeds the budget, avoiding unnecessary IPOG runs at high strengths. Also skips strengths whose initial seed rows alone exceed the budget (the seed is the exhaustive product of the first `t` parameters). The budget is threaded into `generate()` so the FIPOG builder can abort mid-generation instead of building a full array only to discard it.
    ///
    /// - Parameters:
    ///   - budget: Maximum number of rows the covering array may contain.
    ///   - profile: The finite domain profile describing all parameters.
    ///   - maxStrength: Upper bound on the interaction strength to try. Capped internally at 4 (the maximum the FIPOG builder supports). Defaults to 6 for API compatibility.
    public static func bestFitting(budget: UInt64, profile: FiniteDomainProfile, maxStrength: Int = 6) -> CoveringArray? {
        let paramCount = profile.parameters.count
        guard paramCount >= 2 else { return nil }

        let effectiveMax = min(paramCount, maxStrength, 4)
        guard effectiveMax >= 2 else { return nil }

        let rowBudget = Int(min(budget, UInt64(Int.max)))
        var best: CoveringArray?
        for strength in 2 ... effectiveMax {
            // Quick reject: the initial seed is the product of the first t domains.
            // If that alone exceeds the budget, higher strengths will only be worse.
            var seedSize: UInt64 = 1
            var tooBig = false
            for index in 0 ..< strength {
                let (product, overflow) = seedSize.multipliedReportingOverflow(by: profile.parameters[index].domainSize)
                if overflow || product > budget { tooBig = true; break }
                seedSize = product
            }
            if tooBig { break }

            guard let covering = generate(profile: profile, strength: strength, rowBudget: rowBudget) else {
                break
            }
            best = covering
        }
        return best
    }

    /// Generates a covering array using the FIPOG-style IPOG algorithm.
    ///
    /// Builds the array incrementally: starts with an exhaustive enumeration of the first `t` parameters, then extends one parameter at a time via *horizontal growth* (greedily choosing the best value for each existing row) followed by *vertical growth* (adding new rows for any uncovered tuples). Uses bit-vector coverage tracking and strength-specialized hot loops for t=2, 3, and 4.
    ///
    /// Rows are returned in shortlex order (lexicographic, since all rows are equal width).
    ///
    /// - Parameters:
    ///   - profile: The finite domain profile describing all parameters.
    ///   - strength: The interaction strength `t`. Supported values: 1 through 4, or equal to the parameter count (exhaustive). Values above 4 return `nil`.
    ///   - rowBudget: Maximum number of rows. Defaults to 2000.
    /// - Returns: A covering array, or `nil` if generation fails or exceeds the budget.
    public static func generate(profile: FiniteDomainProfile, strength: Int, rowBudget: Int? = nil) -> CoveringArray? {
        let params = profile.parameters
        let paramCount = params.count
        guard strength >= 1, strength <= paramCount else { return nil }

        if strength == paramCount {
            return exhaustive(profile: profile)
        }

        let budget = rowBudget ?? 2000

        // Strength 1: each parameter value appears at least once. max(domains) rows.
        if strength == 1 {
            let maxDomain = params.map(\.domainSize).max() ?? 1
            if maxDomain > UInt64(budget) { return nil }
            var rows: [CoveringArrayRow] = []
            rows.reserveCapacity(Int(maxDomain))
            for row in 0 ..< Int(maxDomain) {
                let values = params.map { UInt64(row) % $0.domainSize }
                rows.append(CoveringArrayRow(values: values))
            }
            rows.sort { $0.values.lexicographicallyPrecedes($1.values) }
            return CoveringArray(strength: 1, rows: rows, profile: profile)
        }

        guard strength <= 4 else { return nil }

        var builder = FIPOGBuilder(domainSizes: params.map(\.domainSize), strength: strength)
        guard builder.run(rowBudget: budget) else { return nil }

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

// MARK: - FIPOG Builder

// FIPOG-style IPOG implementation for covering array generation.
//
// Based on Kleine & Simos (2018) "An efficient design and implementation
// of the in-parameter-order algorithm". Uses bit-vector coverage tracking,
// column-major storage, and strength-specialized hot loops for t=2, 3, 4.
//
// Key differences from the prior hash-based IPOGBuilder:
// - Coverage tracked as one bit per value-tuple (flat integer index) instead of Set<ValueKey>.
// - Column-major UInt16 storage instead of row-major [[UInt64?]].
// - Active-frontier allocation: only slices involving the current parameter are live.
// - Iterative vertical growth with greedy don't-care resolution instead of batch.

/// Bit-vector with unsafe pointer storage for coverage tracking.
///
/// The abstraction boundary for swapping between unsafe and safe storage implementations. All bit operations use wrapping arithmetic for speed.
private struct BitVector {
    private let storage: UnsafeMutablePointer<UInt64>
    let wordCount: Int

    init(bitCount: Int) {
        let words = max((bitCount &+ 63) >> 6, 1)
        wordCount = words
        storage = .allocate(capacity: words)
        storage.initialize(repeating: 0, count: words)
    }

    /// Returns `true` if the bit at `index` is set.
    @inline(__always)
    func isSet(_ index: UInt32) -> Bool {
        let word = Int(index &>> 6)
        let bit = index & 63
        return (storage[word] &>> bit) & 1 != 0
    }

    /// Sets the bit at `index`. Returns `true` if the bit was previously unset (newly covered).
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

    /// Returns the index of the first unset bit below `limit`, or `nil` if all are set.
    func firstUnsetBit(below limit: Int) -> UInt32? {
        let fullWords = limit >> 6
        let remainderBits = limit & 63

        for word in 0 ..< fullWords {
            let value = storage[word]
            if value != UInt64.max {
                let bit = UInt32(word &* 64 &+ (~value).trailingZeroBitCount)
                return bit
            }
        }

        // Check partial last word if limit is not word-aligned.
        if remainderBits > 0, fullWords < wordCount {
            let value = storage[fullWords]
            let mask: UInt64 = (1 &<< remainderBits) &- 1
            let uncovered = ~value & mask
            if uncovered != 0 {
                return UInt32(fullWords &* 64 &+ uncovered.trailingZeroBitCount)
            }
        }

        return nil
    }

    func deallocate() {
        storage.deinitialize(count: wordCount)
        storage.deallocate()
    }
}

/// Tracks coverage for one specific t-tuple of parameter indices.
///
/// Each slice owns a ``BitVector`` where bit `i` represents the `i`-th value combination (packed via precomputed strides). The new parameter occupies the last stride position (stride = 1) for optimal horizontal growth iteration.
private struct CoverageSlice {
    var bits: BitVector

    /// Precomputed strides for flat index computation. Only the first `strength` entries are meaningful. The last meaningful entry is always 1 (the new parameter).
    let strides: (UInt32, UInt32, UInt32, UInt32)

    /// The (t-1) partner parameter indices. Only the first `strength - 1` entries are meaningful.
    let partnerParams: (UInt16, UInt16, UInt16)

    let totalTuples: Int
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
    func flatIndex4(_ value0: UInt16, _ value1: UInt16, _ value2: UInt16, _ value3: UInt16) -> UInt32 {
        UInt32(value0) &* strides.0 &+ UInt32(value1) &* strides.1 &+ UInt32(value2) &* strides.2 &+ UInt32(value3)
    }

    /// Marks the tuple at `index` as covered. Returns `true` if newly covered.
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

/// FIPOG-style IPOG builder using bit-vector coverage and column-major storage.
///
/// Implements the In-Parameter-Order-General algorithm with bit-vector coverage tracking (one bit per value-tuple) instead of hash sets, column-major `UInt16` storage instead of row-major `Optional<UInt64>` arrays, strength-specialized hot loops for t=2, 3, and 4, active-frontier allocation (only slices involving the current parameter are live), and iterative vertical growth with greedy don't-care resolution.
private struct FIPOGBuilder {
    private var domainSizes: ContiguousArray<UInt16>
    private let strength: Int
    private let paramCount: Int
    private var columns: ContiguousArray<ContiguousArray<UInt16>>
    private var rowCount: Int

    init(domainSizes: [UInt64], strength: Int) {
        self.domainSizes = ContiguousArray(domainSizes.map { UInt16(clamping: $0) })
        self.strength = strength
        self.paramCount = domainSizes.count
        self.columns = ContiguousArray()
        self.rowCount = 0
    }

    /// Runs the FIPOG builder with a row budget. Returns `false` if the budget is exceeded at any point.
    mutating func run(rowBudget: Int) -> Bool {
        guard seedInitialRows(rowBudget: rowBudget) else { return false }

        for paramIndex in strength ..< paramCount {
            var slices = allocateSlices(forParameter: paramIndex)

            switch strength {
            case 2: horizontalGrowth2(paramIndex: paramIndex, slices: &slices)
            case 3: horizontalGrowth3(paramIndex: paramIndex, slices: &slices)
            case 4: horizontalGrowth4(paramIndex: paramIndex, slices: &slices)
            default: break
            }

            let succeeded = verticalGrowth(paramIndex: paramIndex, slices: &slices, rowBudget: rowBudget)

            for index in slices.indices {
                slices[index].deallocate()
            }

            if succeeded == false { return false }
        }
        return true
    }

    /// Converts column-major storage to shortlex-sorted ``CoveringArrayRow`` output.
    func finalize() -> [CoveringArrayRow] {
        var rows = [CoveringArrayRow]()
        rows.reserveCapacity(rowCount)

        for row in 0 ..< rowCount {
            var values = [UInt64]()
            values.reserveCapacity(paramCount)
            for param in 0 ..< paramCount {
                values.append(UInt64(columns[param][row]))
            }
            rows.append(CoveringArrayRow(values: values))
        }

        // Shortlex sort — all rows are equal width so shortlex reduces to lexicographic.
        rows.sort { $0.values.lexicographicallyPrecedes($1.values) }

        return rows
    }

    // MARK: - Seed

    /// Generates the full factorial of the first `strength` parameters as the initial seed.
    private mutating func seedInitialRows(rowBudget: Int) -> Bool {
        var seedSize = 1
        for index in 0 ..< strength {
            let (product, overflow) = seedSize.multipliedReportingOverflow(by: Int(domainSizes[index]))
            if overflow || product > rowBudget { return false }
            seedSize = product
        }

        rowCount = seedSize
        columns.reserveCapacity(paramCount)

        for param in 0 ..< strength {
            columns.append(ContiguousArray<UInt16>(repeating: 0, count: seedSize))
        }

        // Rightmost-fastest decomposition for shortlex-biased row ordering.
        for combo in 0 ..< seedSize {
            var remainder = combo
            for param in (0 ..< strength).reversed() {
                let domain = Int(domainSizes[param])
                columns[param][combo] = UInt16(remainder % domain)
                remainder /= domain
            }
        }

        return true
    }

    // MARK: - Slice Allocation

    /// Allocates coverage slices for all C(`paramIndex`, `strength`-1) combinations involving `paramIndex`.
    ///
    /// Each slice tracks one specific combination of `strength` parameters where the last is `paramIndex` (stride = 1). Previous step's slices are deallocated by the caller after growth completes.
    private func allocateSlices(forParameter paramIndex: Int) -> ContiguousArray<CoverageSlice> {
        var slices = ContiguousArray<CoverageSlice>()
        let newDomain = UInt32(domainSizes[paramIndex])

        switch strength {
        case 2:
            slices.reserveCapacity(paramIndex)
            for partner in 0 ..< paramIndex {
                let partnerDomain = UInt32(domainSizes[partner])
                let total = Int(partnerDomain) * Int(newDomain)
                slices.append(CoverageSlice(
                    bits: BitVector(bitCount: total),
                    strides: (newDomain, 1, 0, 0),
                    partnerParams: (UInt16(partner), 0, 0),
                    totalTuples: total,
                    remaining: total
                ))
            }

        case 3:
            slices.reserveCapacity(paramIndex * (paramIndex - 1) / 2)
            for first in 0 ..< paramIndex {
                for second in (first + 1) ..< paramIndex {
                    let domFirst = UInt32(domainSizes[first])
                    let domSecond = UInt32(domainSizes[second])
                    let total = Int(domFirst) * Int(domSecond) * Int(newDomain)
                    let stride0 = domSecond &* newDomain
                    let stride1 = newDomain
                    slices.append(CoverageSlice(
                        bits: BitVector(bitCount: total),
                        strides: (stride0, stride1, 1, 0),
                        partnerParams: (UInt16(first), UInt16(second), 0),
                        totalTuples: total,
                        remaining: total
                    ))
                }
            }

        case 4:
            slices.reserveCapacity(paramIndex * (paramIndex - 1) * (paramIndex - 2) / 6)
            for first in 0 ..< paramIndex {
                for second in (first + 1) ..< paramIndex {
                    for third in (second + 1) ..< paramIndex {
                        let domFirst = UInt32(domainSizes[first])
                        let domSecond = UInt32(domainSizes[second])
                        let domThird = UInt32(domainSizes[third])
                        let total = Int(domFirst) * Int(domSecond) * Int(domThird) * Int(newDomain)
                        let stride0 = domSecond &* domThird &* newDomain
                        let stride1 = domThird &* newDomain
                        let stride2 = newDomain
                        slices.append(CoverageSlice(
                            bits: BitVector(bitCount: total),
                            strides: (stride0, stride1, stride2, 1),
                            partnerParams: (UInt16(first), UInt16(second), UInt16(third)),
                            totalTuples: total,
                            remaining: total
                        ))
                    }
                }
            }

        default:
            break
        }

        return slices
    }

    // MARK: - Horizontal Growth (strength-specialized)

    private mutating func horizontalGrowth2(paramIndex: Int, slices: inout ContiguousArray<CoverageSlice>) {
        let domain = Int(domainSizes[paramIndex])
        let sliceCount = slices.count

        columns.append(ContiguousArray<UInt16>(repeating: 0, count: rowCount))

        for row in 0 ..< rowCount {
            var bestValue: UInt16 = 0
            var bestCount = 0

            for candidate: UInt16 in 0 ..< UInt16(domain) {
                var count = 0
                for slice in 0 ..< sliceCount {
                    let partner = columns[Int(slices[slice].partnerParams.0)][row]
                    let index = slices[slice].flatIndex2(partner, candidate)
                    if slices[slice].isSet(index) == false {
                        count &+= 1
                    }
                }
                if count > bestCount {
                    bestCount = count
                    bestValue = candidate
                }
            }

            columns[paramIndex][row] = bestValue

            for slice in 0 ..< sliceCount {
                let partner = columns[Int(slices[slice].partnerParams.0)][row]
                let index = slices[slice].flatIndex2(partner, bestValue)
                _ = slices[slice].mark(index)
            }
        }
    }

    private mutating func horizontalGrowth3(paramIndex: Int, slices: inout ContiguousArray<CoverageSlice>) {
        let domain = Int(domainSizes[paramIndex])
        let sliceCount = slices.count

        columns.append(ContiguousArray<UInt16>(repeating: 0, count: rowCount))

        for row in 0 ..< rowCount {
            var bestValue: UInt16 = 0
            var bestCount = 0

            for candidate: UInt16 in 0 ..< UInt16(domain) {
                var count = 0
                for slice in 0 ..< sliceCount {
                    let partner0 = columns[Int(slices[slice].partnerParams.0)][row]
                    let partner1 = columns[Int(slices[slice].partnerParams.1)][row]
                    let index = slices[slice].flatIndex3(partner0, partner1, candidate)
                    if slices[slice].isSet(index) == false {
                        count &+= 1
                    }
                }
                if count > bestCount {
                    bestCount = count
                    bestValue = candidate
                }
            }

            columns[paramIndex][row] = bestValue

            for slice in 0 ..< sliceCount {
                let partner0 = columns[Int(slices[slice].partnerParams.0)][row]
                let partner1 = columns[Int(slices[slice].partnerParams.1)][row]
                let index = slices[slice].flatIndex3(partner0, partner1, bestValue)
                _ = slices[slice].mark(index)
            }
        }
    }

    private mutating func horizontalGrowth4(paramIndex: Int, slices: inout ContiguousArray<CoverageSlice>) {
        let domain = Int(domainSizes[paramIndex])
        let sliceCount = slices.count

        columns.append(ContiguousArray<UInt16>(repeating: 0, count: rowCount))

        for row in 0 ..< rowCount {
            var bestValue: UInt16 = 0
            var bestCount = 0

            for candidate: UInt16 in 0 ..< UInt16(domain) {
                var count = 0
                for slice in 0 ..< sliceCount {
                    let partner0 = columns[Int(slices[slice].partnerParams.0)][row]
                    let partner1 = columns[Int(slices[slice].partnerParams.1)][row]
                    let partner2 = columns[Int(slices[slice].partnerParams.2)][row]
                    let index = slices[slice].flatIndex4(partner0, partner1, partner2, candidate)
                    if slices[slice].isSet(index) == false {
                        count &+= 1
                    }
                }
                if count > bestCount {
                    bestCount = count
                    bestValue = candidate
                }
            }

            columns[paramIndex][row] = bestValue

            for slice in 0 ..< sliceCount {
                let partner0 = columns[Int(slices[slice].partnerParams.0)][row]
                let partner1 = columns[Int(slices[slice].partnerParams.1)][row]
                let partner2 = columns[Int(slices[slice].partnerParams.2)][row]
                let index = slices[slice].flatIndex4(partner0, partner1, partner2, bestValue)
                _ = slices[slice].mark(index)
            }
        }
    }

    // MARK: - Vertical Growth

    /// Adds new rows to cover remaining uncovered tuples, one at a time.
    ///
    /// For each uncovered tuple: creates a new row with the tuple's values fixed and free positions filled greedily (try all values, pick coverage-maximizing with smallest-value tiebreak). Returns `false` if the row budget is exceeded.
    private mutating func verticalGrowth(
        paramIndex: Int,
        slices: inout ContiguousArray<CoverageSlice>,
        rowBudget: Int
    ) -> Bool {
        var newRow = ContiguousArray<UInt16>(repeating: 0, count: paramIndex + 1)
        var isFixed = ContiguousArray<Bool>(repeating: false, count: paramIndex + 1)

        while true {
            guard let (sliceIndex, flatIndex) = findFirstUncovered(in: slices) else {
                break
            }
            if rowCount >= rowBudget { return false }

            let tupleValues = decompose(flatIndex: flatIndex, slice: slices[sliceIndex])

            // Reset row to zeros and clear fixed flags.
            for position in 0 ... paramIndex {
                newRow[position] = 0
                isFixed[position] = false
            }

            // Fix the positions dictated by the uncovered tuple.
            fixTuplePositions(
                sliceIndex: sliceIndex,
                tupleValues: tupleValues,
                paramIndex: paramIndex,
                slices: slices,
                row: &newRow,
                fixed: &isFixed
            )

            // Greedily fill free positions to maximize additional coverage.
            for position in 0 ... paramIndex {
                if isFixed[position] { continue }
                var bestValue: UInt16 = 0
                var bestCount = 0

                for candidate: UInt16 in 0 ..< domainSizes[position] {
                    newRow[position] = candidate
                    let count = countUncoveredInRow(newRow, paramIndex: paramIndex, slices: slices)
                    if count > bestCount {
                        bestCount = count
                        bestValue = candidate
                    }
                }
                newRow[position] = bestValue
            }

            // Append row to all active columns.
            for position in 0 ... paramIndex {
                columns[position].append(newRow[position])
            }
            rowCount &+= 1

            markRowCoverage(newRow, paramIndex: paramIndex, slices: &slices)
        }

        return true
    }

    // MARK: - Vertical Growth Helpers

    /// Sets the fixed positions in a new row from the uncovered tuple's values.
    private func fixTuplePositions(
        sliceIndex: Int,
        tupleValues: (UInt16, UInt16, UInt16, UInt16),
        paramIndex: Int,
        slices: ContiguousArray<CoverageSlice>,
        row: inout ContiguousArray<UInt16>,
        fixed: inout ContiguousArray<Bool>
    ) {
        let slice = slices[sliceIndex]

        row[Int(slice.partnerParams.0)] = tupleValues.0
        fixed[Int(slice.partnerParams.0)] = true

        if strength >= 3 {
            row[Int(slice.partnerParams.1)] = tupleValues.1
            fixed[Int(slice.partnerParams.1)] = true
        }
        if strength >= 4 {
            row[Int(slice.partnerParams.2)] = tupleValues.2
            fixed[Int(slice.partnerParams.2)] = true
        }

        // The new parameter's value is always the last in the tuple.
        switch strength {
        case 2:
            row[paramIndex] = tupleValues.1
        case 3:
            row[paramIndex] = tupleValues.2
        case 4:
            row[paramIndex] = tupleValues.3
        default:
            break
        }
        fixed[paramIndex] = true
    }

    /// Finds the first uncovered tuple across all slices by scanning bit vectors in order.
    private func findFirstUncovered(
        in slices: ContiguousArray<CoverageSlice>
    ) -> (sliceIndex: Int, flatIndex: UInt32)? {
        for sliceIndex in 0 ..< slices.count {
            if slices[sliceIndex].remaining == 0 { continue }
            if let bit = slices[sliceIndex].bits.firstUnsetBit(below: slices[sliceIndex].totalTuples) {
                return (sliceIndex, bit)
            }
        }
        return nil
    }

    /// Decomposes a flat index back into per-parameter values using the slice's strides.
    private func decompose(flatIndex: UInt32, slice: CoverageSlice) -> (UInt16, UInt16, UInt16, UInt16) {
        var remainder = flatIndex
        let value0 = UInt16(remainder / slice.strides.0)
        remainder = remainder % slice.strides.0

        switch strength {
        case 2:
            return (value0, UInt16(remainder), 0, 0)
        case 3:
            let value1 = UInt16(remainder / slice.strides.1)
            let value2 = UInt16(remainder % slice.strides.1)
            return (value0, value1, value2, 0)
        case 4:
            let value1 = UInt16(remainder / slice.strides.1)
            remainder = remainder % slice.strides.1
            let value2 = UInt16(remainder / slice.strides.2)
            let value3 = UInt16(remainder % slice.strides.2)
            return (value0, value1, value2, value3)
        default:
            return (0, 0, 0, 0)
        }
    }

    /// Counts how many uncovered tuples the given row would cover across all active slices.
    private func countUncoveredInRow(
        _ row: ContiguousArray<UInt16>,
        paramIndex: Int,
        slices: ContiguousArray<CoverageSlice>
    ) -> Int {
        var count = 0
        let newValue = row[paramIndex]

        for sliceIndex in 0 ..< slices.count {
            let slice = slices[sliceIndex]
            let index: UInt32
            switch strength {
            case 2:
                index = slice.flatIndex2(row[Int(slice.partnerParams.0)], newValue)
            case 3:
                index = slice.flatIndex3(
                    row[Int(slice.partnerParams.0)],
                    row[Int(slice.partnerParams.1)],
                    newValue
                )
            case 4:
                index = slice.flatIndex4(
                    row[Int(slice.partnerParams.0)],
                    row[Int(slice.partnerParams.1)],
                    row[Int(slice.partnerParams.2)],
                    newValue
                )
            default:
                continue
            }
            if slice.isSet(index) == false {
                count &+= 1
            }
        }
        return count
    }

    /// Marks all tuples covered by the given row across all active slices.
    private func markRowCoverage(
        _ row: ContiguousArray<UInt16>,
        paramIndex: Int,
        slices: inout ContiguousArray<CoverageSlice>
    ) {
        let newValue = row[paramIndex]

        for sliceIndex in 0 ..< slices.count {
            let index: UInt32
            switch strength {
            case 2:
                index = slices[sliceIndex].flatIndex2(
                    row[Int(slices[sliceIndex].partnerParams.0)],
                    newValue
                )
            case 3:
                index = slices[sliceIndex].flatIndex3(
                    row[Int(slices[sliceIndex].partnerParams.0)],
                    row[Int(slices[sliceIndex].partnerParams.1)],
                    newValue
                )
            case 4:
                index = slices[sliceIndex].flatIndex4(
                    row[Int(slices[sliceIndex].partnerParams.0)],
                    row[Int(slices[sliceIndex].partnerParams.1)],
                    row[Int(slices[sliceIndex].partnerParams.2)],
                    newValue
                )
            default:
                continue
            }
            _ = slices[sliceIndex].mark(index)
        }
    }
}
