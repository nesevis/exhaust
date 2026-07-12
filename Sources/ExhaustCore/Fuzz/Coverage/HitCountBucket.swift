// AFL-style hit-count bucketing for coverage novelty.

/// Maps raw edge hit counts to coarse buckets so loop-count jitter does not read as novelty.
///
/// An edge that ran 5 times versus 6 times is the same behavior; 3 times versus 30 times is not. The bucket boundaries (1, 2, 3, 4–7, 8–15, 16–31, 32–127, 128+) are AFL's, kept verbatim because they are empirically tuned and the corpus-acceptance criterion — a new (edge, bucket) pair counts as novelty even on an already-covered edge — inherits their behavior.
package enum HitCountBucket {
    /// The number of distinct buckets.
    package static let bucketCount = 8

    /// Returns the bucket index (0–7) for a raw saturating hit count. Zero counts never reach here: sources only report hit edges.
    package static func bucketIndex(for hitCount: UInt8) -> Int {
        switch hitCount {
            case 0, 1:
                0
            case 2:
                1
            case 3:
                2
            case 4 ... 7:
                3
            case 8 ... 15:
                4
            case 16 ... 31:
                5
            case 32 ... 127:
                6
            default:
                7
        }
    }

    /// Returns the bucket as a single-bit mask, for accumulating seen buckets per edge in a `UInt8`.
    package static func bucketMask(for hitCount: UInt8) -> UInt8 {
        1 << UInt8(bucketIndex(for: hitCount))
    }
}
