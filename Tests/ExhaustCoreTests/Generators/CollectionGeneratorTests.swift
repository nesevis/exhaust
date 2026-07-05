//
//  CollectionGeneratorTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("Gen Collection Combinators")
struct CollectionGeneratorTests {
    // MARK: - arrayOf

    @Suite("Gen.arrayOf")
    struct ArrayOfTests {
        @Test("arrayOf(within:) produces lengths within the range")
        func withinRange() throws {
            let gen = Gen.arrayOf(
                Gen.choose(in: 0 ... 100) as Generator<Int>,
                within: 3 ... 7,
                scaling: .constant
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = try iterator.next() {
                #expect(array.count >= 3 && array.count <= 7)
                for element in array {
                    #expect(0 ... 100 ~= element)
                }
                generated += 1
            }
            #expect(generated > 0)
        }

        /// Distribution behavior of .linear and .exponential scaling is verified in
        /// SizeScalingDistributionTests; only the bounds contract is checked here.
        @Test("arrayOf(within:) respects bounds under every scaling", arguments: [SizeScaling<UInt64>.constant, .linear, .exponential])
        func boundsUnderScaling(scaling: SizeScaling<UInt64>) throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 10) as Generator<Int>, within: 0 ... 10, scaling: scaling)
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = try iterator.next() {
                #expect(array.count <= 10)
                generated += 1
            }
            #expect(generated > 0)
        }
    }

    // MARK: - setOf

    @Suite("Gen.setOf")
    struct SetOfTests {
        @Test("Produces sets with unique elements")
        func uniqueElements() throws {
            let gen = Gen.setOf(Gen.choose(in: 0 ... 100) as Generator<Int>)
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
                Gen.choose(in: 0 ... 1000) as Generator<Int>,
                exactly: 5
            )
            var iterator = ValueInterpreter(gen, seed: 1)

            let set = try #require(try iterator.next())
            #expect(set.count == 5)
        }

        @Test("setOf with range")
        func withinRange() throws {
            let gen = Gen.setOf(
                Gen.choose(in: 0 ... 1000) as Generator<Int>,
                within: 2 ... 5,
                scaling: .constant
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
                Gen.choose(in: 0 ... 100) as Generator<Int>,
                Gen.choose(in: 0 ... 100) as Generator<Int>
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

        @Test("Colliding keys collapse to unique keys within the key range")
        func duplicateKeys() throws {
            // A three-value key range forces collisions; the dictionary invariant
            // is that keys stay unique and inside the range regardless.
            let gen = Gen.dictionaryOf(
                Gen.choose(in: 0 ... 2) as Generator<Int>,
                Gen.choose(in: 0 ... 100) as Generator<Int>
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            var sawFullKeySpace = false
            while let dict = try iterator.next() {
                for key in dict.keys {
                    #expect(0 ... 2 ~= key)
                }
                if dict.count == 3 { sawFullKeySpace = true }
                generated += 1
            }
            #expect(generated > 0)
            #expect(sawFullKeySpace, "With keys in 0...2, some dictionary should reach all three keys")
        }
    }

    // MARK: - shuffled

    @Suite("Gen.shuffled")
    struct ShuffledTests {
        @Test("Empty collection returns empty")
        func emptyCollection() throws {
            let gen = Gen.shuffled(Gen.arrayOf(
                Gen.choose(in: 0 ... 10) as Generator<Int>,
                exactly: 0
            ))
            var iterator = ValueInterpreter(gen, seed: 1)

            let result = try #require(try iterator.next())
            #expect(result.isEmpty)
        }

        @Test("Single element returns that element")
        func singleElement() throws {
            let gen = Gen.shuffled(Gen.arrayOf(
                Gen.choose(in: 42 ... 42) as Generator<Int>,
                exactly: 1
            ))
            var iterator = ValueInterpreter(gen, seed: 1)

            let result = try #require(try iterator.next())
            #expect(result == [42])
        }

        @Test("Shuffled array contains same elements")
        func preservesElements() throws {
            let gen = Gen.arrayOf(
                Gen.choose(in: 0 ... 100) as Generator<Int>,
                exactly: 5
            ).bind { array in
                Gen.shuffled(Generator<[Int]>.pure(array)).map { shuffled in
                    (array.sorted(), shuffled.sorted())
                }
            }
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 20)

            var checked = 0
            while let (original, shuffled) = try iterator.next() {
                #expect(original == shuffled)
                checked += 1
            }
            #expect(checked == 20)
        }

        @Test("Produces different permutations across draws")
        func differentPermutations() throws {
            let source = [1, 2, 3, 4, 5]
            let gen = Gen.shuffled(Generator<[Int]>.pure(source))

            var permutations: Set<[Int]> = []
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 20)
            while let result = try iterator.next() {
                permutations.insert(result)
            }
            #expect(permutations.count > 1, "Expected multiple different permutations")
        }
    }

    // MARK: - sized

    @Suite("Gen.sized")
    struct SizedTests {
        @Test("Produces arrays respecting size")
        func respectsSize() throws {
            let gen = Gen.sized(Gen.choose(in: 0 ... 100) as Generator<Int>)
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
                Gen.choose(in: 0 ... 10) as Generator<Int>,
                lengthRange: 0 ... 1000
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            // The size parameter (at most 100) caps the effective upper bound.
            var generated = 0
            while let array = try iterator.next() {
                #expect(array.count <= 100, "Should be clamped by size parameter")
                generated += 1
            }
            #expect(generated > 0)
        }
    }

    // MARK: - element and choose(from:)

    @Suite("Gen.element")
    struct ElementTests {
        @Test("Hashable element picks from collection")
        func hashableElement() throws {
            let collection = [10, 20, 30, 40, 50]
            let gen: Generator<Int> = Gen.element(from: collection)
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 20)

            var drawn = 0
            while let value = try iterator.next() {
                #expect(collection.contains(value))
                drawn += 1
            }
            #expect(drawn == 20)
        }

        @Test("Non-Hashable element picks from collection")
        func nonHashableElement() throws {
            let collection = [NonHashableWrapper(value: 1), NonHashableWrapper(value: 2), NonHashableWrapper(value: 3)]
            let gen: Generator<NonHashableWrapper> = Gen.element(from: collection)
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 20)

            var drawn = 0
            while let value = try iterator.next() {
                #expect(collection.contains(value))
                drawn += 1
            }
            #expect(drawn == 20)
        }

        @Test("element(from:) is reflectable")
        func elementFromIsReflectable() throws {
            let gen: Generator<Int> = Gen.element(from: [10, 20, 30, 40, 50])

            var iterator = ValueInterpreter(gen, seed: 42)
            let value = try #require(try iterator.next())

            let tree = try Interpreters.reflect(gen, with: value)
            #expect(tree != nil, ".element(from:) should be reflectable")
        }

        @Test("element(from: CaseIterable.allCases) reaches every case")
        func elementFromCaseIterableReachesAllCases() throws {
            let gen = Gen.element(from: CollectionDirection.allCases)
            var seen: Set<CollectionDirection> = []

            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 100)
            while let value = try iterator.next() {
                seen.insert(value)
                if seen.count == CollectionDirection.allCases.count { break }
            }

            #expect(seen.count == CollectionDirection.allCases.count, "Expected all 4 directions, got \(seen)")
        }

        @Test("choose(from: [true, false]) produces both values")
        func chooseFromBoolProducesBothValues() throws {
            let gen: Generator<Bool> = Gen.choose(from: [true, false])
            var sawTrue = false
            var sawFalse = false

            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 50)
            while let value = try iterator.next() {
                if value { sawTrue = true } else { sawFalse = true }
                if sawTrue, sawFalse { break }
            }

            #expect(sawTrue, "Expected at least one true")
            #expect(sawFalse, "Expected at least one false")
        }
    }
}

// MARK: - Helpers

private struct NonHashableWrapper: Equatable {
    let value: Int
}

private enum CollectionDirection: CaseIterable, Hashable {
    case north, south, east, west
}
