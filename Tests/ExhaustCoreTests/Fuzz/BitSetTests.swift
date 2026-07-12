import ExhaustCore
import Testing

@Suite("BitSet coverage signature tests")
struct BitSetTests {
    @Test("Empty set contains nothing and reports zero count")
    func emptySet() {
        let bitSet = BitSet(capacity: 100)
        #expect(bitSet.isEmpty)
        #expect(bitSet.isEmpty)
        #expect(bitSet.contains(0) == false)
        #expect(bitSet.contains(99) == false)
        #expect(bitSet.indices.isEmpty)
    }

    @Test("Insert and contains round-trip across word boundaries")
    func insertAndContains() {
        var bitSet = BitSet(capacity: 200)
        let inserted = [0, 1, 63, 64, 65, 127, 128, 199]
        for index in inserted {
            bitSet.insert(index)
        }
        for index in inserted {
            #expect(bitSet.contains(index))
        }
        #expect(bitSet.count == inserted.count)
        #expect(bitSet.indices == inserted)
        #expect(bitSet.contains(2) == false)
        #expect(bitSet.contains(126) == false)
    }

    @Test("Repeated insert is idempotent")
    func repeatedInsert() {
        var bitSet = BitSet(capacity: 10)
        bitSet.insert(5)
        bitSet.insert(5)
        #expect(bitSet.count == 1)
    }

    @Test("contains outside capacity returns false without trapping")
    func containsOutsideCapacity() {
        let bitSet = BitSet(capacity: 10)
        #expect(bitSet.contains(10) == false)
        #expect(bitSet.contains(-1) == false)
        #expect(bitSet.contains(Int.max) == false)
    }

    @Test("Union combines indices from both sets")
    func union() {
        var first = BitSet(capacity: 128)
        first.insert(1)
        first.insert(64)
        var second = BitSet(capacity: 128)
        second.insert(2)
        second.insert(64)

        let combined = first.union(second)
        #expect(combined.indices == [1, 2, 64])

        first.formUnion(second)
        #expect(first == combined)
    }

    @Test("Intersection keeps only shared indices")
    func intersection() {
        var first = BitSet(capacity: 128)
        first.insert(1)
        first.insert(64)
        first.insert(100)
        var second = BitSet(capacity: 128)
        second.insert(64)
        second.insert(100)
        second.insert(127)

        let shared = first.intersection(second)
        #expect(shared.indices == [64, 100])

        first.formIntersection(second)
        #expect(first == shared)
    }

    @Test("Subtracting removes the other set's indices")
    func subtracting() {
        var first = BitSet(capacity: 70)
        first.insert(1)
        first.insert(65)
        var second = BitSet(capacity: 70)
        second.insert(65)

        let difference = first.subtracting(second)
        #expect(difference.indices == [1])
    }

    @Test("Disjointness and subset relations")
    func disjointAndSubset() {
        var first = BitSet(capacity: 64)
        first.insert(3)
        var second = BitSet(capacity: 64)
        second.insert(3)
        second.insert(40)
        var third = BitSet(capacity: 64)
        third.insert(40)
        third.insert(41)

        #expect(first.isSubset(of: second))
        #expect(second.isSubset(of: first) == false)
        #expect(first.isDisjoint(with: third))
        #expect(second.isDisjoint(with: third) == false)
        #expect(BitSet(capacity: 64).isSubset(of: first))
    }

    @Test("Jaccard similarity matches hand-computed ratios")
    func jaccardSimilarity() {
        var first = BitSet(capacity: 64)
        first.insert(1)
        first.insert(2)
        first.insert(3)
        var second = BitSet(capacity: 64)
        second.insert(2)
        second.insert(3)
        second.insert(4)

        // Intersection {2, 3}, union {1, 2, 3, 4}.
        #expect(first.jaccardSimilarity(to: second) == 0.5)
        #expect(first.jaccardSimilarity(to: first) == 1.0)
        #expect(BitSet(capacity: 64).jaccardSimilarity(to: BitSet(capacity: 64)) == 1.0)

        var empty = BitSet(capacity: 64)
        #expect(empty.jaccardSimilarity(to: first) == 0.0)
        empty.insert(60)
        #expect(empty.jaccardSimilarity(to: first) == 0.0)
    }

    @Test("forEachIndex visits indices in ascending order")
    func forEachIndexOrder() {
        var bitSet = BitSet(capacity: 300)
        let inserted = [299, 0, 128, 64, 63]
        for index in inserted {
            bitSet.insert(index)
        }
        var visited: [Int] = []
        bitSet.forEachIndex { visited.append($0) }
        #expect(visited == [0, 63, 64, 128, 299])
    }

    @Test("Equality and hashing agree for equal contents")
    func equalityAndHashing() {
        var first = BitSet(capacity: 128)
        var second = BitSet(capacity: 128)
        for index in [7, 77, 127] {
            first.insert(index)
            second.insert(index)
        }
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)

        second.insert(8)
        #expect(first != second)
    }

    @Test("Zero-capacity set is valid and empty")
    func zeroCapacity() {
        let bitSet = BitSet(capacity: 0)
        #expect(bitSet.isEmpty)
        #expect(bitSet.isEmpty)
        #expect(bitSet.contains(0) == false)
    }
}
