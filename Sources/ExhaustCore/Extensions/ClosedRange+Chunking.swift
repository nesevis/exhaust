package extension ClosedRange where Bound == UInt64 {
    /// Count of values in the range, saturating at `UInt64.max` when the range spans `0...UInt64.max`.
    ///
    /// The naive expression `upperBound - lowerBound + 1` traps on the full-domain case because the true count is `2^64`, not representable as `UInt64`. Callers that only need an upper bound for clamping or thresholding should use this instead.
    var saturatingCount: UInt64 {
        let span = upperBound &- lowerBound
        let (incremented, overflow) = span.addingReportingOverflow(1)
        return overflow ? UInt64.max : incremented
    }

    /// Splits the range into `chunks` roughly equal sub-ranges, distributing any remainder across the leading sub-ranges.
    func split(into chunks: Int) -> [ClosedRange<UInt64>] {
        guard chunks > 0 else { return [] }
        guard chunks > 1 else { return [self] }

        // Compute totalSize = upperBound - lowerBound + 1 with overflow detection.
        // The only case that overflows is 0...UInt64.max (size = 2^64, not representable).
        let distance = upperBound - lowerBound
        let (totalSize, overflowed) = distance.addingReportingOverflow(1)

        let chunkSize: UInt64
        let chunkRemainder: UInt64
        if overflowed {
            // Full UInt64 domain: size is 2^64. Derive quotient/remainder from UInt64.max = 2^64 - 1.
            // UInt64.max = q * chunks + r, so 2^64 = q * chunks + r + 1.
            let chunksU = UInt64(chunks)
            let (q, r) = UInt64.max.quotientAndRemainder(dividingBy: chunksU)
            if r == chunksU - 1 {
                chunkSize = q + 1
                chunkRemainder = 0
            } else {
                chunkSize = q
                chunkRemainder = r + 1
            }
        } else {
            (chunkSize, chunkRemainder) = totalSize.quotientAndRemainder(dividingBy: UInt64(chunks))
        }

        var result: [ClosedRange<UInt64>] = []
        result.reserveCapacity(chunks)

        var start = lowerBound

        for i in 0 ..< chunks {
            let extra: UInt64 = UInt64(i) < chunkRemainder ? 1 : 0
            let size = chunkSize + extra
            guard size > 0 else { break }
            // Compute end = start + (size - 1) to avoid the overflow that (start + size) - 1 can cause when start + size exceeds UInt64.max.
            let (tentativeEnd, overflow) = start.addingReportingOverflow(size - 1)
            let end = (overflow || tentativeEnd > upperBound) ? upperBound : tentativeEnd

            result.append(start ... end)
            guard end < upperBound else { break }
            start = end + 1  // Safe: end < upperBound guarantees end + 1 <= upperBound.
        }

        return result
    }
}
