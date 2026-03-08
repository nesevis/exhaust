//
//  CharacterSet+Ranges.swift
//  Exhaust
//

import Foundation

// MARK: - ScalarRangeSet

/// A set of `UInt32` ranges representing Unicode scalar values, backed by `RangeSet`.
/// Provides O(log n) index-to-scalar lookup for single-pick generation.
public struct ScalarRangeSet: Sendable {
    public let rangeSet: RangeSet<UInt32>

    /// Cached sorted, non-overlapping ranges (avoids re-allocating on every lookup).
    private let rangesArray: [Range<UInt32>]

    /// Number of distinct ranges after coalescing.
    public var rangeCount: Int {
        rangesArray.count
    }

    /// Total number of scalar values across all ranges.
    public let scalarCount: Int

    /// Cumulative sizes for O(log n) index lookup. `cumulativeCounts[i]` = total scalars in ranges 0..<i.
    private let cumulativeCounts: [Int]

    public init(_ rangeSet: RangeSet<UInt32>) {
        precondition(!rangeSet.isEmpty, "ScalarRangeSet requires a non-empty RangeSet")
        self.rangeSet = rangeSet
        rangesArray = Array(rangeSet.ranges)
        var cumulative: [Int] = []
        cumulative.reserveCapacity(rangesArray.count)
        var total = 0
        for range in rangesArray {
            cumulative.append(total)
            total += range.count
        }
        scalarCount = total
        cumulativeCounts = cumulative
    }

    /// Maps a flat index in `0..<scalarCount` to the corresponding `Unicode.Scalar`.
    /// Uses binary search over cumulative range sizes for O(log n) lookup.
    /// Out-of-range indices are clamped so the shrinker can safely explore candidates.
    public func scalar(at index: Int) -> Unicode.Scalar {
        let clamped = min(max(index, 0), scalarCount - 1)
        let rangeIndex = rangeIndex(forFlatIndex: clamped)
        let offsetInRange = clamped - cumulativeCounts[rangeIndex]
        let scalarValue = rangesArray[rangeIndex].lowerBound + UInt32(offsetInRange)
        return Unicode.Scalar(scalarValue)!
    }

    /// Maps a scalar back to its flat index in `0..<scalarCount`.
    /// Uses binary search over the cached ranges for O(log n) lookup.
    public func index(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        var lo = 0
        var hi = rangesArray.count - 1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let range = rangesArray[mid]
            if value < range.lowerBound {
                hi = mid - 1
            } else if value >= range.upperBound {
                lo = mid + 1
            } else {
                return cumulativeCounts[mid] + Int(value - range.lowerBound)
            }
        }
        preconditionFailure("Scalar U+\(String(value, radix: 16, uppercase: true)) not found in ScalarRangeSet")
    }

    /// Binary search for the range index containing the given flat index.
    private func rangeIndex(forFlatIndex index: Int) -> Int {
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
}

// MARK: - CharacterSet → ScalarRangeSet

extension CharacterSet {
    /// Parses `bitmapRepresentation` into a `ScalarRangeSet` of `UInt32` scalar values.
    ///
    /// - Plane 0 (BMP): first 8192 bytes, 1 bit per scalar U+0000…U+FFFF
    /// - Planes 1–16: each occupied plane appends 8193 bytes (1-byte plane index + 8192-byte bitmap)
    public func scalarRangeSet() -> ScalarRangeSet {
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
            extractRanges(from: bitmap, byteStart: offset, planeBase: planeIndex &* 0x10000, into: &rangeSet)
            offset += planeSize
        }

        // Surrogates (U+D800–U+DFFF) appear in the BMP bitmap but aren't valid Unicode scalars.
        rangeSet.remove(contentsOf: 0xD800 ..< 0xE000)

        return ScalarRangeSet(rangeSet)
    }

    // MARK: - Bitmap parsing into RangeSet<UInt32>

    private func extractRanges(
        from bitmap: Data,
        byteStart: Int,
        planeBase: UInt32,
        into rangeSet: inout RangeSet<UInt32>,
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
