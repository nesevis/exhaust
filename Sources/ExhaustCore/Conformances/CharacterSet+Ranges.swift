//
//  CharacterSet+Ranges.swift
//  Exhaust
//

import Foundation

// MARK: - ScalarRangeSet

/// A set of `UInt32` ranges representing Unicode scalar values, backed by ``RangeSet``.
/// Provides O(log n) index-to-scalar lookup for single-pick generation.
///
/// When ``bottomCodepoint`` is non-nil, index 0 is reserved for that scalar and all other indices are offset by 1. The bottom codepoint does not need to be a member of the underlying range set. This makes the reducer (which shrinks toward bit pattern 0, that is, index 0) converge toward the nominated character without any pipeline changes.
package struct ScalarRangeSet: Sendable {
    /// The underlying set of Unicode scalar value ranges.
    public let rangeSet: RangeSet<UInt32>

    /// Cached sorted, non-overlapping ranges (avoids re-allocating on every lookup).
    private let rangesArray: [Range<UInt32>]

    /// Number of distinct ranges after coalescing.
    public var rangeCount: Int {
        rangesArray.count
    }

    /// Total number of scalar values across all ranges, plus one for the bottom codepoint if present.
    public let scalarCount: Int

    /// Cumulative sizes for O(log n) index lookup. `cumulativeCounts[i]` = total scalars in ranges 0..<i.
    private let cumulativeCounts: [Int]

    /// When non-nil, index 0 maps to this scalar and all range-derived indices are offset by 1.
    public let bottomCodepoint: Unicode.Scalar?

    /// Creates a ``ScalarRangeSet`` from a `RangeSet<UInt32>`, optionally pinning index zero to `bottomCodepoint` so the reducer converges toward that scalar.
    public init(_ rangeSet: RangeSet<UInt32>, bottomCodepoint: Unicode.Scalar? = nil) {
        precondition(!rangeSet.isEmpty, "ScalarRangeSet requires a non-empty RangeSet")
        self.rangeSet = rangeSet
        self.bottomCodepoint = bottomCodepoint
        rangesArray = Array(rangeSet.ranges)
        var cumulative: [Int] = []
        cumulative.reserveCapacity(rangesArray.count)
        var total = 0
        for range in rangesArray {
            cumulative.append(total)
            total += range.count
        }
        let rangeTotal = total
        scalarCount = bottomCodepoint != nil ? rangeTotal + 1 : rangeTotal
        cumulativeCounts = cumulative
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
        let rangeTotal = cumulativeCounts.last.map { $0 + rangesArray.last!.count } ?? 0
        let clamped = min(max(rangeRelativeIndex, 0), rangeTotal - 1)
        let rangeIdx = rangeIndexForFlatIndex(clamped)
        let offsetInRange = clamped - cumulativeCounts[rangeIdx]
        let scalarValue = rangesArray[rangeIdx].lowerBound + UInt32(offsetInRange)
        return Unicode.Scalar(scalarValue)!
    }

    /// Binary search for the range index containing the given flat index.
    private func rangeIndexForFlatIndex(_ index: Int) -> Int {
        var lo = 0
        var hi = cumulativeCounts.count - 1
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
        var rangeSet = RangeSet<UInt32>()

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

    // MARK: - Bitmap parsing into RangeSet<UInt32>

    private func extractRanges(
        from bitmap: Data,
        byteStart: Int,
        planeBase: UInt32,
        into rangeSet: inout RangeSet<UInt32>
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
