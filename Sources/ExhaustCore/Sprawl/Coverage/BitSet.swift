// Fixed-capacity bitset used for per-attempt coverage signatures.

/// A set of edge indices backed by packed `UInt64` words.
///
/// Coverage signatures are compared, unioned, and intersected millions of times per soak run, so the representation is a flat word array rather than `Set<Int>`: a 1,000-edge module needs 16 words (~128 bytes), and set algebra is word-parallel. Capacity is fixed at init to the instrumented edge count; all signatures in a run share the same capacity, which keeps binary operations index-aligned without bounds negotiation.
///
/// Hashable so cluster identity can key on (reduced form, signature) pairs.
package struct BitSet: Hashable, Sendable {
    /// Packed storage, least significant bit of word 0 is index 0.
    private var words: ContiguousArray<UInt64>

    /// The number of indices this set can hold, as given at init. Not the population count.
    package let capacity: Int

    /// Creates an empty set able to hold indices `0 ..< capacity`.
    package init(capacity: Int) {
        precondition(capacity >= 0, "BitSet capacity must be non-negative")
        self.capacity = capacity
        words = ContiguousArray(repeating: 0, count: (capacity + 63) / 64)
    }

    // MARK: - Element Access

    /// Inserts the given index.
    package mutating func insert(_ index: Int) {
        precondition(index >= 0 && index < capacity, "Index \(index) out of range 0..<\(capacity)")
        words[index >> 6] |= 1 << UInt64(index & 63)
    }

    /// Returns whether the given index is present.
    package func contains(_ index: Int) -> Bool {
        guard index >= 0, index < capacity else {
            return false
        }
        return words[index >> 6] & (1 << UInt64(index & 63)) != 0
    }

    /// The number of indices present.
    package var count: Int {
        var total = 0
        for word in words {
            total += word.nonzeroBitCount
        }
        return total
    }

    /// Whether no indices are present.
    package var isEmpty: Bool {
        words.allSatisfy { $0 == 0 }
    }

    // MARK: - Set Algebra

    // Binary operations require equal capacity: signatures from the same run always share the instrumented edge count, and a mismatch means two different builds' signatures are being compared, which is a caller bug.

    /// Adds every index of `other` to this set.
    package mutating func formUnion(_ other: BitSet) {
        precondition(capacity == other.capacity, "BitSet capacity mismatch: \(capacity) vs \(other.capacity)")
        for wordIndex in words.indices {
            words[wordIndex] |= other.words[wordIndex]
        }
    }

    /// Returns the union of this set and `other`.
    package func union(_ other: BitSet) -> BitSet {
        var result = self
        result.formUnion(other)
        return result
    }

    /// Removes every index not present in `other`.
    package mutating func formIntersection(_ other: BitSet) {
        precondition(capacity == other.capacity, "BitSet capacity mismatch: \(capacity) vs \(other.capacity)")
        for wordIndex in words.indices {
            words[wordIndex] &= other.words[wordIndex]
        }
    }

    /// Returns the intersection of this set and `other`.
    package func intersection(_ other: BitSet) -> BitSet {
        var result = self
        result.formIntersection(other)
        return result
    }

    /// Returns the indices present in this set but absent from `other`.
    package func subtracting(_ other: BitSet) -> BitSet {
        precondition(capacity == other.capacity, "BitSet capacity mismatch: \(capacity) vs \(other.capacity)")
        var result = self
        for wordIndex in result.words.indices {
            result.words[wordIndex] &= ~other.words[wordIndex]
        }
        return result
    }

    /// Returns whether this set and `other` share no indices.
    package func isDisjoint(with other: BitSet) -> Bool {
        precondition(capacity == other.capacity, "BitSet capacity mismatch: \(capacity) vs \(other.capacity)")
        for wordIndex in words.indices where words[wordIndex] & other.words[wordIndex] != 0 {
            return false
        }
        return true
    }

    /// Returns whether every index of this set is present in `other`.
    package func isSubset(of other: BitSet) -> Bool {
        precondition(capacity == other.capacity, "BitSet capacity mismatch: \(capacity) vs \(other.capacity)")
        for wordIndex in words.indices where words[wordIndex] & ~other.words[wordIndex] != 0 {
            return false
        }
        return true
    }

    /// The Jaccard similarity between this set and `other`: |A ∩ B| / |A ∪ B|, or 1 when both are empty.
    ///
    /// Used at report time to find the passing signatures nearest a cluster's necessary-edge set.
    package func jaccardSimilarity(to other: BitSet) -> Double {
        precondition(capacity == other.capacity, "BitSet capacity mismatch: \(capacity) vs \(other.capacity)")
        var intersectionCount = 0
        var unionCount = 0
        for wordIndex in words.indices {
            intersectionCount += (words[wordIndex] & other.words[wordIndex]).nonzeroBitCount
            unionCount += (words[wordIndex] | other.words[wordIndex]).nonzeroBitCount
        }
        guard unionCount > 0 else {
            return 1
        }
        return Double(intersectionCount) / Double(unionCount)
    }

    // MARK: - Iteration

    /// Calls `body` for each present index in ascending order.
    ///
    /// A callback instead of `Sequence` conformance: the hot-loop consumers (corpus admission, rarity updates) only ever scan forward once, and the callback form avoids iterator allocation without closing the door on adding conformance later.
    package func forEachIndex(_ body: (Int) -> Void) {
        for wordIndex in words.indices {
            var word = words[wordIndex]
            while word != 0 {
                let bit = word.trailingZeroBitCount
                body(wordIndex << 6 | bit)
                word &= word - 1
            }
        }
    }

    /// All present indices in ascending order.
    package var indices: [Int] {
        var result: [Int] = []
        result.reserveCapacity(count)
        forEachIndex { result.append($0) }
        return result
    }
}
