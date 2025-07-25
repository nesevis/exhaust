extension ClosedRange where Bound == UInt64 {
    func split(into chunks: Int) -> [ClosedRange<UInt64>] {
        guard chunks > 0 else { return [] }
        guard chunks > 1 else { return [self] }
        
        let totalSize = upperBound - lowerBound + 1
        let chunkSize = totalSize / UInt64(chunks)
        let remainder = totalSize % UInt64(chunks)
        
        var result: [ClosedRange<UInt64>] = []
        result.reserveCapacity(chunks)
        
        var start = lowerBound
        
        for i in 0..<chunks {
            let extraOne = i < remainder ? 1 : 0
            let size = chunkSize + UInt64(extraOne) 
            let end = start + size - 1
            
            result.append(start...Swift.min(end, upperBound))
            start = end + 1
            
            if start > upperBound { break }
        }
        
        return result
    }
    
    func equallySpaced(count: Int) -> [UInt64] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [lowerBound] }
        
        let totalSize = upperBound - lowerBound
        guard totalSize > 0 else { return [] }
        
        var result: [UInt64] = []
        result.reserveCapacity(count)
        
        for i in 0..<count {
            let position = (totalSize * UInt64(i)) / UInt64(count - 1)
            result.append(lowerBound + position)
        }
        
        return result
    }
}

// For unsigned values
extension ClosedRange where Bound: Comparable, Bound: FixedWidthInteger {
    func equallySpacedExcludingBounds(count: Bound) -> [Bound] {
        guard isEmpty == false else { return [] }
        let count = count + 2 // Avoiding anchoring close to the extremes
        
        let totalSize = upperBound - lowerBound
        guard totalSize > count, count > 0 else {
            return []
        }
        
        let spacing = totalSize / count + 1
        
        var result: [Bound] = []
        result.reserveCapacity(Int(count))
        
        for i in 2...count - 1 {
            result.append(lowerBound + spacing * i)
        }
        
        return result
    }
}

// For signed values
extension ClosedRange where Bound: Comparable, Bound: FixedWidthInteger & SignedInteger {
    func equallySpacedExcludingBounds(count: Bound) -> [Bound] {
        guard isEmpty == false else { return [] }
        let count = count + 2 // Avoiding anchoring close to the extremes
        
        var result: [Bound] = []
        if upperBound &- lowerBound == -1 {
            // We've wrapped. This is a huge range, so split it in half
            let totalSize = upperBound
            let spacing = totalSize / (count * 2) + 1
            for i in 1...Int(count / 2) {
                let value = lowerBound + spacing * Bound(i)
                result.append(value)
                result.append(abs(value))
            }
        } else {
            // The range is mappable
            let totalSize = upperBound - lowerBound
            guard totalSize > count, count > 0 else {
                return []
            }
            
            let spacing = totalSize / count + 1
            
            var result: [Bound] = []
            result.reserveCapacity(Int(count))
            
            for i in 2...count - 1 {
                result.append(lowerBound + spacing * i)
            }
        }
        
        return result
    }
}

// FIXME: This needs testing
extension ClosedRange where Bound: Comparable, Bound: BinaryFloatingPoint {
    func equallySpacedExcludingBounds(count: Bound) -> [Bound] {
        guard isEmpty == false, count > 0 else { return [] }
        
        var result: [Bound] = []
        result.reserveCapacity(Int(count))
        var totalSize = upperBound - lowerBound
        if totalSize.isInfinite {
            totalSize = .greatestFiniteMagnitude
            // We're dealing with a range larger than .greatestFiniteMagnitude, so split the difference between negative and positive
            let spacing = totalSize / (count * 2) + 1
            for i in 1...Int(count / 2) {
                let value = lowerBound + spacing * Bound(i)
                result.append(value)
                result.append(abs(value))
            }
        } else {
            guard totalSize > count else {
                return []
            }
            let spacing = totalSize / count + 1
            
            for i in 1...Int(count) {
                result.append(lowerBound + spacing * Bound(i))
            }
        }
        print("\(Self.self) returning \(result.count) results for range \(self)")
        return result
    }
}
