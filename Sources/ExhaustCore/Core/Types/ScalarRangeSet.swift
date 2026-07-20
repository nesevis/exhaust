//
//  ScalarRangeSet.swift
//  Exhaust
//

import Foundation

// MARK: - ScalarRangeSet

/// A set of `UInt32` ranges representing Unicode scalar values, backed by ``ExhaustRangeSet``.
/// Provides O(log n) index-to-scalar lookup for single-pick generation.
///
/// When ``bottomCodepoint`` is non-nil, index 0 is reserved for that scalar and all other indices are offset by 1. The bottom codepoint does not need to be a member of the underlying range set; if it is a member, it is removed from the range set so that index 0 remains its only address — otherwise ``scalar(at:)`` and ``index(of:)`` would disagree on the duplicate index and reflection round-trips would fail. This makes the reducer (which reduces toward bit pattern 0, that is, index 0) converge toward the nominated character without any pipeline changes.
package struct ScalarRangeSet: @unchecked Sendable {
    /// The underlying set of Unicode scalar value ranges.
    public let rangeSet: ExhaustRangeSet<UInt32>

    /// Cached sorted, non-overlapping ranges (avoids re-allocating on every lookup).
    private let rangesArray: [Range<UInt32>]

    /// Number of distinct ranges after coalescing.
    public var rangeCount: Int {
        rangesArray.count
    }

    /// Total number of addressable scalar values: the range set count plus the reserved bottom-codepoint index when present.
    public let scalarCount: Int

    /// Cumulative sizes for O(log n) index lookup. `cumulativeCounts[i]` = total scalars in ranges 0..<i.
    private let cumulativeCounts: [Int]

    /// Total number of scalars covered by the ranges alone, excluding the reserved bottom-codepoint index.
    private let rangeTotal: Int

    /// Right-shift applied to a flat index to find its bucket in ``searchHints``.
    private let hintShift: Int

    /// Maps each bucket of flat indices to the index of the range containing the bucket's first flat index. Index-to-scalar lookup is on the per-character generation hot path, so ``rangeIndexForFlatIndex(_:)`` uses this table to narrow its binary search to the few ranges a bucket spans — for typical character sets the search collapses to one or two probes.
    private let searchHints: [Int32]

    /// When non-nil, index 0 maps to this scalar and all range-derived indices are offset by 1.
    public let bottomCodepoint: Unicode.Scalar?

    /// Pre-computed flat indices for ``ProblematicValues/interestingCharacterScalars`` that are present in this range set. Passed to ``TypeTag/character(problematicIndices:)`` so problematic-value analysis receives correct index-space values.
    public let problematicIndices: [UInt64]

    /// Creates a ``ScalarRangeSet`` from a `ExhaustRangeSet<UInt32>`, optionally pinning index zero to `bottomCodepoint` so the reducer converges toward that scalar.
    public init(_ rangeSet: ExhaustRangeSet<UInt32>, bottomCodepoint: Unicode.Scalar? = nil) {
        precondition(!rangeSet.isEmpty, "ScalarRangeSet requires a non-empty ExhaustRangeSet")

        var rangeSet = rangeSet
        if let bottom = bottomCodepoint, rangeSet.contains(bottom.value) {
            rangeSet.remove(contentsOf: bottom.value ..< bottom.value + 1)
        }

        let rangesArray = Array(rangeSet.ranges)
        var cumulative: [Int] = []
        cumulative.reserveCapacity(rangesArray.count)
        var total = 0
        for range in rangesArray {
            cumulative.append(total)
            total += range.count
        }

        var problematicIndices = ProblematicValues.interestingCharacterScalars
            .compactMap { candidate -> UInt64? in
                guard rangeSet.contains(candidate) else {
                    return nil
                }
                let rangeIndex = Self.naturalIndex(
                    of: candidate,
                    ranges: rangesArray,
                    cumulativeCounts: cumulative
                )
                return UInt64(bottomCodepoint != nil ? rangeIndex + 1 : rangeIndex)
            }
        // The bottom codepoint was removed from the range set above, so an interesting bottom scalar is reachable only through its reserved index.
        if let bottom = bottomCodepoint,
           ProblematicValues.interestingCharacterScalars.contains(bottom.value)
        {
            problematicIndices.insert(0, at: 0)
        }

        // Pick the smallest shift that keeps the hint table at no more than four buckets per range — small enough to stay cache-resident, fine enough that most buckets span a single range.
        var shift = 0
        while total > 1 && ((total - 1) >> shift) + 1 > 4 * rangesArray.count {
            shift += 1
        }
        let bucketCount = ((total - 1) >> shift) + 1
        var hints: [Int32] = []
        hints.reserveCapacity(bucketCount)
        var hintRangeIndex = 0
        for bucket in 0 ..< bucketCount {
            let flatIndex = bucket << shift
            while hintRangeIndex + 1 < rangesArray.count, cumulative[hintRangeIndex + 1] <= flatIndex {
                hintRangeIndex += 1
            }
            hints.append(Int32(hintRangeIndex))
        }

        self.rangeSet = rangeSet
        self.bottomCodepoint = bottomCodepoint
        // The bottom code point, if present, is always removed from the range set and kept at index 0
        scalarCount = bottomCodepoint != nil ? total + 1 : total
        cumulativeCounts = cumulative
        rangeTotal = total
        hintShift = shift
        searchHints = hints
        self.rangesArray = rangesArray
        self.problematicIndices = problematicIndices
    }

    /// Maps a flat index in `0..<scalarCount` to the corresponding `Unicode.Scalar`.
    /// Uses binary search over cumulative range sizes for O(log n) lookup.
    /// Out-of-range indices are clamped so the reducer can safely explore candidates.
    public func scalar(at index: Int) -> Unicode.Scalar {
        let clamped = min(max(index, 0), scalarCount - 1)
        if let bottom = bottomCodepoint {
            if clamped == 0 { return bottom }
            let rangeIndex = clamped - 1
            return rangeScalar(at: rangeIndex)
        }
        return rangeScalar(at: clamped)
    }

    /// Whether this range set contains the given scalar.
    public func contains(_ scalar: Unicode.Scalar) -> Bool {
        if let bottom = bottomCodepoint, scalar == bottom { return true }
        return rangeSet.contains(scalar.value)
    }

    /// Maps a scalar back to its flat index in `0..<scalarCount`.
    /// Uses binary search over the cached ranges for O(log n) lookup.
    public func index(of scalar: Unicode.Scalar) -> Int {
        if let bottom = bottomCodepoint, scalar == bottom {
            return 0
        }
        let rangeIndex = Self.naturalIndex(
            of: scalar.value,
            ranges: rangesArray,
            cumulativeCounts: cumulativeCounts
        )
        return bottomCodepoint != nil ? rangeIndex + 1 : rangeIndex
    }

    // MARK: - Internal Lookup

    /// Maps a range-relative index to a Unicode scalar (no bottom-codepoint offset applied).
    private func rangeScalar(at rangeRelativeIndex: Int) -> Unicode.Scalar {
        let clamped = min(max(rangeRelativeIndex, 0), rangeTotal - 1)
        let rangeIdx = rangeIndexForFlatIndex(clamped)
        let offsetInRange = clamped - cumulativeCounts[rangeIdx]
        let scalarValue = rangesArray[rangeIdx].lowerBound + UInt32(offsetInRange)
        return Unicode.Scalar(scalarValue)!
    }

    /// Binary search for the range index containing the given flat index, narrowed to the bucket bounds from ``searchHints``.
    private func rangeIndexForFlatIndex(_ index: Int) -> Int {
        let bucket = index >> hintShift
        var lo = Int(searchHints[bucket])
        var hi = bucket + 1 < searchHints.count
            ? Int(searchHints[bucket + 1])
            : cumulativeCounts.count - 1
        while lo < hi {
            let mid = lo + (hi - lo + 1) / 2
            if cumulativeCounts[mid] <= index {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// Finds the range-relative index of a scalar value. Precondition-fails if the scalar is not in the range set.
    private static func naturalIndex(
        of value: UInt32,
        ranges: [Range<UInt32>],
        cumulativeCounts: [Int]
    ) -> Int {
        var lo = 0
        var hi = ranges.count - 1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let range = ranges[mid]
            if value < range.lowerBound {
                hi = mid - 1
            } else if value >= range.upperBound {
                lo = mid + 1
            } else {
                return cumulativeCounts[mid] + Int(value - range.lowerBound)
            }
        }
        let hex = String(value, radix: 16, uppercase: true)
        preconditionFailure(
            "Scalar U+\(hex) not found in ScalarRangeSet"
        )
    }
}

// MARK: - CharacterSet → ScalarRangeSet

extension CharacterSet {
    /// Parses `bitmapRepresentation` into a ``ScalarRangeSet`` of `UInt32` scalar values.
    ///
    /// - Parameter bottomCodepoint: When non-nil, reserves index 0 for this scalar and offsets all range-derived indices by 1. The scalar does not need to be a member of the character set.
    /// - Plane 0 (BMP): first 8192 bytes, 1 bit per scalar U+0000…U+FFFF
    /// - Planes 1–16: each occupied plane appends 8193 bytes (1-byte plane index + 8192-byte bitmap)
    package func scalarRangeSet(bottomCodepoint: Unicode.Scalar? = nil) -> ScalarRangeSet {
        let bitmap = bitmapRepresentation
        let planeSize = 8192
        var rangeSet = ExhaustRangeSet<UInt32>()

        precondition(bitmap.count >= planeSize, "CharacterSet bitmapRepresentation is malformed")

        // Plane 0 (BMP)
        extractRanges(from: bitmap, byteStart: 0, planeBase: 0, into: &rangeSet)

        // Supplementary planes 1–16
        var offset = planeSize
        while offset + 1 + planeSize <= bitmap.count {
            let planeIndex = UInt32(bitmap[offset])
            offset += 1
            extractRanges(
                from: bitmap,
                byteStart: offset,
                planeBase: planeIndex &* 0x10000,
                into: &rangeSet
            )
            offset += planeSize
        }

        // Surrogates (U+D800–U+DFFF) appear in the BMP bitmap but aren't valid Unicode scalars.
        rangeSet.remove(contentsOf: 0xD800 ..< 0xE000)

        return ScalarRangeSet(rangeSet, bottomCodepoint: bottomCodepoint)
    }

    // MARK: - Bitmap parsing into ExhaustRangeSet<UInt32>

    private func extractRanges(
        from bitmap: Data,
        byteStart: Int,
        planeBase: UInt32,
        into rangeSet: inout ExhaustRangeSet<UInt32>
    ) {
        var rangeStart: UInt32?
        var rangeEnd: UInt32 = 0

        for byteIndex in 0 ..< 8192 {
            let byte = bitmap[byteStart + byteIndex]
            let scalarBase = planeBase + UInt32(byteIndex) * 8

            if byte == 0x00 {
                if let start = rangeStart {
                    rangeSet.insert(contentsOf: start ..< rangeEnd + 1)
                    rangeStart = nil
                }
                continue
            }

            if byte == 0xFF {
                if rangeStart == nil { rangeStart = scalarBase }
                rangeEnd = scalarBase + 7
                continue
            }

            for bit in 0 ..< UInt32(8) {
                let scalar = scalarBase + bit
                if byte & (1 << bit) != 0 {
                    if rangeStart == nil { rangeStart = scalar }
                    rangeEnd = scalar
                } else if let start = rangeStart {
                    rangeSet.insert(contentsOf: start ..< rangeEnd + 1)
                    rangeStart = nil
                }
            }
        }

        if let start = rangeStart {
            rangeSet.insert(contentsOf: start ..< rangeEnd + 1)
        }
    }
}
