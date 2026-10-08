/// Pre-computes the lane partition of a tagged command sequence for reuse across repetitions of the same candidate.
///
/// Caching the partition avoids rebuilding the lane buckets and the sorted ``laneIDs`` array on every probe during reduction, where the same candidate is tested 25–100 times.
///
/// The partition is built from schedule markers alone and stores `Int` positions into the caller's tagged array rather than copies of the commands. This keeps the type non-generic: inside this (whole-module-optimized) binary the bucket construction runs as concrete code instead of an unspecialized generic, no command values are copied through value witnesses, and executors iterate buckets by indexing the original array.
package struct LanePartition: Sendable {
    /// Positions of prefix-marked commands, in input order.
    package let prefixIndices: [Int]
    /// The distinct non-prefix marker values present, sorted ascending.
    package let laneIDs: [UInt8]
    /// Positions of each lane's commands, keyed by marker value, in per-lane input order.
    package let laneBuckets: [UInt8: [Int]]
    /// Positions of all non-prefix commands, grouped by ascending lane and in per-lane input order — the order the sequential reference replays them in.
    package let concurrentIndices: [Int]

    package init(markers: [ScheduleMarker]) {
        var prefix: [Int] = []
        var ids: [UInt8] = []
        var buckets: [UInt8: [Int]] = [:]
        for (index, marker) in markers.enumerated() {
            if marker.isPrefix {
                prefix.append(index)
            } else {
                if ids.contains(marker.rawValue) == false {
                    ids.append(marker.rawValue)
                }
                buckets[marker.rawValue, default: []].append(index)
            }
        }
        ids.sort()
        prefixIndices = prefix
        laneIDs = ids
        laneBuckets = buckets
        concurrentIndices = ids.flatMap { buckets[$0] ?? [] }
    }
}
