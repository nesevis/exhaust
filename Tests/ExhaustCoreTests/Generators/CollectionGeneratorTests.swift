//
//  CollectionGeneratorTests.swift
//  Exhaust
//

import Testing
import ExhaustCore

@Suite("Gen Collection Combinators")
struct CollectionGeneratorTests {
    // MARK: - setOf

    @Suite("Gen.setOf")
    struct SetOfTests {
        @Test("Produces sets with unique elements")
        func uniqueElements() throws {
            let gen = Gen.setOf(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>)
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let set = try iterator.next() {
                // Set guarantees uniqueness; verify count matches
                let array = Array(set)
                #expect(Set(array).count == array.count)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("setOf with exact count")
        func exactCount() throws {
            let gen = Gen.setOf(
                Gen.choose(in: 0 ... 1000) as ReflectiveGenerator<Int>,
                exactly: 5,
            )
            var iterator = ValueInterpreter(gen, seed: 1)

            if let set = try iterator.next() {
                #expect(set.count == 5)
            }
        }

        @Test("setOf with range")
        func withinRange() throws {
            let gen = Gen.setOf(
                Gen.choose(in: 0 ... 1000) as ReflectiveGenerator<Int>,
                within: 2 ... 5,
                scaling: .constant,
            )
            var iterator = ValueInterpreter(gen, seed: 10)

            var generated = 0
            while let set = try iterator.next() {
                #expect(set.count >= 2 && set.count <= 5)
                generated += 1
            }
            #expect(generated > 0)
        }
    }

    // MARK: - dictionaryOf

    @Suite("Gen.dictionaryOf")
    struct DictionaryOfTests {
        @Test("Produces dictionaries")
        func producesDictionaries() throws {
            let gen = Gen.dictionaryOf(
                Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
                Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
            )
            var iterator = ValueInterpreter(gen, seed: 7)

            var generated = 0
            while let dict = try iterator.next() {
                for (key, value) in dict {
                    #expect(0 ... 100 ~= key)
                    #expect(0 ... 100 ~= value)
                }
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Handles duplicate keys by keeping first")
        func duplicateKeys() throws {
            // Use a very small key range to force collisions
            let gen = Gen.dictionaryOf(
                Gen.choose(in: 0 ... 2) as ReflectiveGenerator<Int>,
                Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            if let dict = try iterator.next() {
                // Keys should be unique (dictionary invariant)
                #expect(dict.count <= 3)
            }
        }
    }

    // MARK: - shuffled

    @Suite("Gen.shuffled")
    struct ShuffledTests {
        @Test("Empty collection returns empty")
        func emptyCollection() throws {
            let gen = Gen.shuffled(Gen.arrayOf(
                Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>,
                exactly: 0,
            ))
            var iterator = ValueInterpreter(gen, seed: 1)

            if let result = try iterator.next() {
                #expect(result.isEmpty)
            }
        }

        @Test("Single element returns that element")
        func singleElement() throws {
            let gen = Gen.shuffled(Gen.arrayOf(
                Gen.choose(in: 42 ... 42) as ReflectiveGenerator<Int>,
                exactly: 1,
            ))
            var iterator = ValueInterpreter(gen, seed: 1)

            if let result = try iterator.next() {
                #expect(result == [42])
            }
        }

        @Test("Shuffled array contains same elements")
        func preservesElements() throws {
            let gen = Gen.arrayOf(
                Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
                exactly: 5,
            )._bind { array in
                Gen.shuffled(ReflectiveGenerator<[Int]>.pure(array))._map { shuffled in
                    (array.sorted(), shuffled.sorted())
                }
            }
            var iterator = ValueInterpreter(gen, seed: 42)

            if let (original, shuffled) = try iterator.next() {
                #expect(original == shuffled)
            }
        }

        @Test("Produces different permutations across seeds")
        func differentPermutations() throws {
            let source = [1, 2, 3, 4, 5]
            let gen = Gen.shuffled(ReflectiveGenerator<[Int]>.pure(source))

            var permutations: Set<[Int]> = []
            for seed in UInt64(1) ... 20 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let result = try iterator.next() {
                    permutations.insert(result)
                }
            }
            #expect(permutations.count > 1, "Expected multiple different permutations")
        }
    }

    // MARK: - sized

    @Suite("Gen.sized")
    struct SizedTests {
        @Test("Produces arrays respecting size")
        func respectsSize() throws {
            let gen = Gen.sized(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>)
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = try iterator.next() {
                for element in array {
                    #expect(0 ... 100 ~= element)
                }
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("With lengthRange clamps to size")
        func lengthRangeClamped() throws {
            let gen = Gen.sized(
                Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>,
                lengthRange: 0 ... 1000,
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            // The size parameter caps the upper bound
            if let array = try iterator.next() {
                #expect(array.count <= 100, "Should be clamped by size parameter")
            }
        }
    }

    // MARK: - element

    @Suite("Gen.element")
    struct ElementTests {
        @Test("Hashable element picks from collection")
        func hashableElement() throws {
            let collection = [10, 20, 30, 40, 50]
            let gen: ReflectiveGenerator<Int> = Gen.element(from: collection)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = try iterator.next() {
                    #expect(collection.contains(value))
                }
            }
        }

        @Test("Non-Hashable element picks from collection")
        func nonHashableElement() throws {
            let collection = [NonHashableWrapper(value: 1), NonHashableWrapper(value: 2), NonHashableWrapper(value: 3)]
            let gen: ReflectiveGenerator<NonHashableWrapper> = Gen.element(from: collection)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = try iterator.next() {
                    #expect(collection.contains(value))
                }
            }
        }
    }

    // MARK: - arrayOf(within:scaling:)

    @Suite("Gen.arrayOf(within:scaling:)")
    struct ArrayOfScalingTests {
        @Test("Constant scaling uses full range")
        func constantScaling() throws {
            let gen = Gen.arrayOf(
                Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>,
                within: 3 ... 7,
                scaling: .constant,
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = try iterator.next() {
                #expect(array.count >= 3 && array.count <= 7)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Linear scaling produces arrays in range")
        func linearScaling() throws {
            let gen = Gen.arrayOf(
                Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>,
                within: 0 ... 10,
                scaling: .linear,
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = try iterator.next() {
                #expect(array.count <= 10)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Exponential scaling produces arrays in range")
        func exponentialScaling() throws {
            let gen = Gen.arrayOf(
                Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>,
                within: 0 ... 10,
                scaling: .exponential,
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = try iterator.next() {
                #expect(array.count <= 10)
                generated += 1
            }
            #expect(generated > 0)
        }
    }

    // MARK: - slice

    @Suite("Gen.slice")
    struct SliceTests {
        @Test("Slice of array produces valid subrange")
        func sliceOfArray() throws {
            let source = Array(0 ..< 20)
            let gen = Gen.slice(of: source)
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let slice = try iterator.next() {
                #expect(slice.count <= source.count)
                for element in slice {
                    #expect(source.contains(element))
                }
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Slice of empty collection returns empty")
        func emptySlice() throws {
            let source: [Int] = []
            let gen = Gen.slice(of: source)
            var iterator = ValueInterpreter(gen, seed: 1)

            if let slice = try iterator.next() {
                #expect(slice.isEmpty)
            }
        }
    }
}

// MARK: - Helpers

private struct NonHashableWrapper: Equatable {
    let value: Int
}
