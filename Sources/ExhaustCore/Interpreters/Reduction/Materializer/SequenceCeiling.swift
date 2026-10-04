/// Caps the flattened history length of a terminal lift. A nil maximum imposes no cap.
///
/// Discarded backtrack auditions are not part of the selected result, so the materializer suspends the ceiling while they run.
struct SequenceCeiling {
    let maximumCount: Int?

    /// Whether an array of scalar elements fits, counting its elements plus the sequence's two markers. Enclosing structure only adds entries, so a rejection here is final.
    func admits(arrayLength: UInt64) -> Bool {
        guard let maximumCount else {
            return true
        }
        return maximumCount >= 2 && arrayLength <= UInt64(maximumCount - 2)
    }
}

extension Materializer.Context {
    /// Suspends the lower-bound check while an audition can still be discarded in favor of another arm.
    mutating func withSuspendedSequenceCeiling<Result>(
        _ body: (inout Self) throws -> Result
    ) rethrows -> Result {
        let saved = sequenceCeiling
        sequenceCeiling = SequenceCeiling(maximumCount: nil)
        defer { self.sequenceCeiling = saved }
        return try body(&self)
    }
}
