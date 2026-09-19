import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("BitSet coverage signature tests")
struct BitSetTests {
    @Test("Empty set contains nothing and reports zero count")
    func emptySet() {
        let bitSet = BitSet(capacity: 100)
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

    @Test("Set algebra agrees with Set<Int> over generated capacities and index lists")
    func setAlgebraAgreesWithSetModel() throws {
        let capacities: Generator<Int> = Gen.choose(in: 1 ... 200)
        let pairs = capacities.bind { capacity in
            Gen.zip(
                Gen.arrayOf(Gen.choose(in: 0 ... capacity - 1) as Generator<Int>, within: 0 ... 64),
                Gen.arrayOf(Gen.choose(in: 0 ... capacity - 1) as Generator<Int>, within: 0 ... 64)
            ).map { (capacity, $0.0, $0.1) }
        }
        try exhaustCheck(pairs, maxIterations: 300) { capacity, left, right in
            var first = BitSet(capacity: capacity)
            var second = BitSet(capacity: capacity)
            for index in left {
                first.insert(index)
            }
            for index in right {
                second.insert(index)
            }
            let firstModel = Set(left)
            let secondModel = Set(right)
            return first.indices == firstModel.sorted()
                && second.indices == secondModel.sorted()
                && first.count == firstModel.count
                && first.union(second).indices == firstModel.union(secondModel).sorted()
                && first.intersection(second).indices == firstModel.intersection(secondModel).sorted()
                && first.subtracting(second).indices == firstModel.subtracting(secondModel).sorted()
                && first.isSubset(of: second) == firstModel.isSubset(of: secondModel)
                && first.isDisjoint(with: second) == firstModel.isDisjoint(with: secondModel)
        }
    }

    @Test("Zero-capacity set is valid and empty")
    func zeroCapacity() {
        let bitSet = BitSet(capacity: 0)
        #expect(bitSet.isEmpty)
        #expect(bitSet.contains(0) == false)
    }
}
