/// Pre-computes the lane partition of a tagged command sequence for reuse across repetitions of the same candidate.
///
/// Caching the partition avoids rebuilding the ``laneBuckets`` dictionary and the sorted ``laneIDs`` array on every probe during reduction, where the same candidate is tested 25–100 times.
package struct LanePartition<Command> {
    package let prefixCommands: [Command]
    package let laneIDs: [UInt8]
    package let laneBuckets: [UInt8: [Command]]
    package let concurrentCommands: [Command]

    package init(_ taggedCommands: [(ScheduleMarker, Command)]) {
        var prefix: [Command] = []
        var ids: [UInt8] = []
        var buckets: [UInt8: [Command]] = [:]
        for (marker, command) in taggedCommands {
            if marker.isPrefix {
                prefix.append(command)
            } else {
                if ids.contains(marker.rawValue) == false {
                    ids.append(marker.rawValue)
                }
                buckets[marker.rawValue, default: []].append(command)
            }
        }
        ids.sort()
        prefixCommands = prefix
        laneIDs = ids
        laneBuckets = buckets
        concurrentCommands = ids.flatMap { buckets[$0] ?? [] }
    }
}
