public extension ClosedRange where Bound == UInt64 {
    func split(into chunks: Int) -> [ClosedRange<UInt64>] {
        guard chunks > 0 else { return [] }
        guard chunks > 1 else { return [self] }

        let totalSize = upperBound - lowerBound + 1
        let chunkSize = totalSize / UInt64(chunks)
        let remainder = totalSize % UInt64(chunks)

        var result: [ClosedRange<UInt64>] = []
        result.reserveCapacity(chunks)

        var start = lowerBound

        for i in 0 ..< chunks {
            let extraOne = i < remainder ? 1 : 0
            let size = chunkSize + UInt64(extraOne)
            let end = start + size - 1

            result.append(start ... Swift.min(end, upperBound))
            start = end + 1

            if start > upperBound { break }
        }

        return result
    }
}
