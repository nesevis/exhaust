//
//  ConformanceTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("Public API Conformances")
struct ConformanceTests {
    // MARK: - Collections

    @Suite("Collection conformances")
    struct Collections {
        // MARK: Static methods

        @Test("Static .array(gen) produces arrays")
        func staticArray() throws {
            let gen: ReflectiveGenerator<[Int]> = Gen.arrayOf(Gen.choose(in: 0 ... 100))
            var iterator = ValueInterpreter(gen, seed: 42)

            if let array = try iterator.next() {
                for element in array {
                    #expect(0 ... 100 ~= element)
                }
            }
        }

        @Test("Static .array(gen, length:) produces fixed-range arrays")
        func staticArrayWithLength() throws {
            let gen: ReflectiveGenerator<[Int]> = Gen.arrayOf(
                Gen.choose(in: 0 ... 100),
                within: 3 ... 5
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = try iterator.next() {
                #expect(array.count >= 3 && array.count <= 5)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Static .array(gen, length:) with linear scaling")
        func staticArrayLinear() throws {
            let gen: ReflectiveGenerator<[Int]> = Gen.arrayOf(Gen.choose(in: 0 ... 10), within: 0 ... 10, scaling: .linear)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = try iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Static .array(gen, length:) with constant scaling")
        func staticArrayConstant() throws {
            let gen: ReflectiveGenerator<[Int]> = Gen.arrayOf(Gen.choose(in: 0 ... 10), within: 0 ... 10, scaling: .constant)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = try iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Static .array(gen, length:) with exponential scaling")
        func staticArrayExponential() throws {
            let gen: ReflectiveGenerator<[Int]> = Gen.arrayOf(Gen.choose(in: 0 ... 10), within: 0 ... 10, scaling: .exponential)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = try iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Static .set(gen) produces sets")
        func staticSet() throws {
            let gen: ReflectiveGenerator<Set<Int>> = Gen.setOf(Gen.choose(in: 0 ... 1000))
            var iterator = ValueInterpreter(gen, seed: 42)

            if let set = try iterator.next() {
                for element in set {
                    #expect(0 ... 1000 ~= element)
                }
            }
        }

        @Test("Static .set(gen, count:) produces bounded sets")
        func staticSetWithCount() throws {
            let gen: ReflectiveGenerator<Set<Int>> = Gen.setOf(
                Gen.choose(in: 0 ... 1000),
                within: 2 ... 5,
                scaling: .constant
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let set = try iterator.next() {
                #expect(set.count >= 2 && set.count <= 5)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Static .dictionary(k, v) produces dictionaries")
        func staticDictionary() throws {
            let gen: ReflectiveGenerator<[Int: Int]> = Gen.dictionaryOf(
                Gen.choose(in: 0 ... 100),
                Gen.choose(in: 0 ... 100)
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            if let dict = try iterator.next() {
                for (key, value) in dict {
                    #expect(0 ... 100 ~= key)
                    #expect(0 ... 100 ~= value)
                }
            }
        }

        @Test("Static .shuffled(gen) produces shuffled array")
        func staticShuffled() throws {
            let source = ReflectiveGenerator<[Int]>.pure([1, 2, 3, 4, 5])
            let gen: ReflectiveGenerator<[Int]> = Gen.shuffled(source)
            var iterator = ValueInterpreter(gen, seed: 42)

            if let result = try iterator.next() {
                #expect(result.sorted() == [1, 2, 3, 4, 5])
            }
        }

        // MARK: Instance methods

        @Test("Instance .array() produces arrays")
        func instanceArray() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>)
            var iterator = ValueInterpreter(gen, seed: 42)

            if let array = try iterator.next() {
                for element in array {
                    #expect(0 ... 100 ~= element)
                }
            }
        }

        @Test("Instance .array(length:scaling:) with linear scaling")
        func instanceArrayLinear() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>, within: 0 ... 10, scaling: .linear)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = try iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Instance .array(length:scaling:) with constant scaling")
        func instanceArrayConstant() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>, within: 0 ... 10, scaling: .constant)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = try iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Instance .array(length:scaling:) with exponential scaling")
        func instanceArrayExponential() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>, within: 0 ... 10, scaling: .exponential)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = try iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Instance .set() produces sets")
        func instanceSet() throws {
            let gen = Gen.setOf(Gen.choose(in: 0 ... 1000) as ReflectiveGenerator<Int>)
            var iterator = ValueInterpreter(gen, seed: 42)

            if let set = try iterator.next() {
                for element in set {
                    #expect(0 ... 1000 ~= element)
                }
            }
        }

        @Test("Instance .set(count:) produces bounded sets")
        func instanceSetWithCount() throws {
            let gen = Gen.setOf(
                Gen.choose(in: 0 ... 1000) as ReflectiveGenerator<Int>,
                within: 2 ... 5,
                scaling: .constant
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let set = try iterator.next() {
                #expect(set.count >= 2 && set.count <= 5)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Instance .shuffled() produces shuffled collection")
        func instanceShuffled() throws {
            let gen = Gen.shuffled(ReflectiveGenerator<[Int]>.pure([1, 2, 3, 4, 5]))
            var iterator = ValueInterpreter(gen, seed: 42)

            if let result = try iterator.next() {
                #expect(result.sorted() == [1, 2, 3, 4, 5])
            }
        }

        @Test("Instance .element() on Hashable collection")
        func instanceElementHashable() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>, exactly: 5)
                ._bind { array in
                    Gen.element(from: array)._map { element in
                        (array, element)
                    }
                }
            var iterator = ValueInterpreter(gen, seed: 42)

            if let (array, element) = try iterator.next() {
                #expect(array.contains(element))
            }
        }

        @Test("Static .element(from:) is reflectable")
        func elementFromIsReflectable() throws {
            let gen: ReflectiveGenerator<Int> = Gen.element(from: [10, 20, 30, 40, 50])

            var iterator = ValueInterpreter(gen, seed: 42)
            let value = try #require(try iterator.next())

            let tree = try Interpreters.reflect(gen, with: value)
            #expect(tree != nil, ".element(from:) should be reflectable")
        }
    }

    // MARK: - Numeric generators

    @Suite("Numeric conformances")
    struct Numerics {
        // MARK: Double

        @Test("double() produces doubles")
        func doubleDefault() throws {
            let gen: ReflectiveGenerator<Double> = Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling)
            var iterator = ValueInterpreter(gen, seed: 42)
            #expect(try iterator.next() != nil)
        }

        @Test("double(in:) with explicit range")
        func doubleInRange() throws {
            let gen: ReflectiveGenerator<Double> = Gen.choose(in: 0.0 ... 1.0)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = try iterator.next() {
                    #expect(0.0 ... 1.0 ~= value)
                }
            }
        }

        @Test("double(in:scaling:) with explicit scaling")
        func doubleWithScaling() throws {
            let gen: ReflectiveGenerator<Double> = Gen.choose(in: -10.0 ... 10.0, scaling: .constant)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = try iterator.next() {
                    #expect(-10.0 ... 10.0 ~= value)
                }
            }
        }

        // MARK: Float

        @Test("float() produces floats")
        func floatDefault() throws {
            let gen: ReflectiveGenerator<Float> = Gen.choose(in: -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude, scaling: Float.defaultScaling)
            var iterator = ValueInterpreter(gen, seed: 42)
            #expect(try iterator.next() != nil)
        }

        @Test("float(in:) with Float range")
        func floatInRange() throws {
            let gen: ReflectiveGenerator<Float> = Gen.choose(in: Float(0.0) ... Float(1.0))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = try iterator.next() {
                    #expect(Float(0.0) ... Float(1.0) ~= value)
                }
            }
        }

        @Test("float(in:) with Double range convenience")
        func floatInDoubleRange() throws {
            let gen: ReflectiveGenerator<Float> = Gen.choose(in: Float(0.0) ... Float(1.0))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = try iterator.next() {
                    #expect(Float(0.0) ... Float(1.0) ~= value)
                }
            }
        }

        // MARK: Signed integers

        @Test("int8() with and without range")
        func int8Gen() throws {
            let gen1: ReflectiveGenerator<Int8> = Gen.choose(in: Int8.min ... Int8.max, scaling: Int8.defaultScaling)
            let gen2: ReflectiveGenerator<Int8> = Gen.choose(in: Int8(-10) ... Int8(10))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(-10 ... 10 ~= v)
            }
        }

        @Test("int16() with and without range")
        func int16Gen() throws {
            let gen1: ReflectiveGenerator<Int16> = Gen.choose(in: Int16.min ... Int16.max, scaling: Int16.defaultScaling)
            let gen2: ReflectiveGenerator<Int16> = Gen.choose(in: Int16(-100) ... Int16(100))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(-100 ... 100 ~= v)
            }
        }

        @Test("int32() with and without range")
        func int32Gen() throws {
            let gen1: ReflectiveGenerator<Int32> = Gen.choose(in: Int32.min ... Int32.max, scaling: Int32.defaultScaling)
            let gen2: ReflectiveGenerator<Int32> = Gen.choose(in: Int32(-1000) ... Int32(1000))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(-1000 ... 1000 ~= v)
            }
        }

        @Test("int64() with and without range")
        func int64Gen() throws {
            let gen1: ReflectiveGenerator<Int64> = Gen.choose(in: Int64.min ... Int64.max, scaling: Int64.defaultScaling)
            let gen2: ReflectiveGenerator<Int64> = Gen.choose(in: Int64(-1000) ... Int64(1000))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(-1000 ... 1000 ~= v)
            }
        }

        @Test("int() with and without range")
        func intGen() throws {
            let gen1: ReflectiveGenerator<Int> = Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling)
            let gen2: ReflectiveGenerator<Int> = Gen.choose(in: -1000 ... 1000)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(-1000 ... 1000 ~= v)
            }
        }

        // MARK: Unsigned integers

        @Test("uint8() with and without range")
        func uint8Gen() throws {
            let gen1: ReflectiveGenerator<UInt8> = Gen.choose(in: UInt8.min ... UInt8.max, scaling: UInt8.defaultScaling)
            let gen2: ReflectiveGenerator<UInt8> = Gen.choose(in: UInt8(0) ... UInt8(50))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(0 ... 50 ~= v)
            }
        }

        @Test("uint16() with and without range")
        func uint16Gen() throws {
            let gen1: ReflectiveGenerator<UInt16> = Gen.choose(in: UInt16.min ... UInt16.max, scaling: UInt16.defaultScaling)
            let gen2: ReflectiveGenerator<UInt16> = Gen.choose(in: UInt16(0) ... UInt16(500))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(0 ... 500 ~= v)
            }
        }

        @Test("uint32() with and without range")
        func uint32Gen() throws {
            let gen1: ReflectiveGenerator<UInt32> = Gen.choose(in: UInt32.min ... UInt32.max, scaling: UInt32.defaultScaling)
            let gen2: ReflectiveGenerator<UInt32> = Gen.choose(in: UInt32(0) ... UInt32(5000))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(0 ... 5000 ~= v)
            }
        }

        @Test("uint64() with and without range")
        func uint64Gen() throws {
            let gen1: ReflectiveGenerator<UInt64> = Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)
            let gen2: ReflectiveGenerator<UInt64> = Gen.choose(in: UInt64(0) ... UInt64(10000))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(0 ... 10000 ~= v)
            }
        }

        @Test("uint() with and without range")
        func uintGen() throws {
            let gen1: ReflectiveGenerator<UInt> = Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling)
            let gen2: ReflectiveGenerator<UInt> = Gen.choose(in: UInt(0) ... UInt(10000))
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(try iter1.next() != nil)
            if let v = try iter2.next() {
                #expect(0 ... 10000 ~= v)
            }
        }
    }

    // MARK: - Miscellaneous

    @Suite("Miscellaneous conformances")
    struct Miscellaneous {
        @Test("bool() produces both true and false")
        func boolBothValues() throws {
            let gen: ReflectiveGenerator<Bool> = boolGen()
            var sawTrue = false
            var sawFalse = false

            for seed in UInt64(1) ... 20 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = try iterator.next() {
                    if value { sawTrue = true } else { sawFalse = true }
                }
                if sawTrue, sawFalse { break }
            }

            #expect(sawTrue, "Expected at least one true")
            #expect(sawFalse, "Expected at least one false")
        }

        @Test("Instance .optional() produces both nil and non-nil")
        func instanceOptional() throws {
            let gen = optionalGen(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>)
            var sawNil = false
            var sawSome = false

            for seed in UInt64(1) ... 50 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = try iterator.next() {
                    if value == nil { sawNil = true } else { sawSome = true }
                }
                if sawNil, sawSome { break }
            }

            #expect(sawNil, "Expected at least one nil")
            #expect(sawSome, "Expected at least one non-nil")
        }

        @Test("oneOf for CaseIterable produces all cases")
        func oneOfCaseIterable() throws {
            let gen = Gen.element(from: ConformanceDirection.allCases)
            var seen: Set<String> = []

            for seed in UInt64(1) ... 50 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = try iterator.next() {
                    seen.insert("\(value)")
                }
                if seen.count == 4 { break }
            }

            #expect(seen.count == 4, "Expected all 4 directions, got \(seen)")
        }

        @Test(".just() produces constant value")
        func justConstant() throws {
            let gen: ReflectiveGenerator<Int> = Gen.just(42)
            var iterator = ValueInterpreter(gen, seed: 1)
            #expect(try iterator.next() == 42)
        }

        @Test("oneOf(generators...) picks from generators")
        func oneOfGenerators() throws {
            let gen: ReflectiveGenerator<Int> = Gen.pick(choices: [
                (1, Gen.choose(in: 0 ... 0)),
                (1, Gen.choose(in: 100 ... 100)),
            ])
            var sawZero = false
            var sawHundred = false

            for seed in UInt64(1) ... 50 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = try iterator.next() {
                    if value == 0 { sawZero = true }
                    if value == 100 { sawHundred = true }
                }
                if sawZero, sawHundred { break }
            }

            #expect(sawZero, "Expected to see 0")
            #expect(sawHundred, "Expected to see 100")
        }

        @Test("oneOf(weighted:) respects weights")
        func oneOfWeighted() throws {
            let gen: ReflectiveGenerator<Int> = Gen.pick(choices: [
                (100, Gen.choose(in: 0 ... 0)),
                (1, Gen.choose(in: 100 ... 100)),
            ])

            var counts = [0: 0, 100: 0]
            for seed in UInt64(1) ... 200 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = try iterator.next() {
                    counts[value, default: 0] += 1
                }
            }

            // Heavily weighted toward 0
            #expect(counts[0, default: 0] > counts[100, default: 0],
                    "Expected 0 to appear more often than 100")
        }
    }
}

// MARK: - Helpers

private enum ConformanceDirection: CaseIterable {
    case north, south, east, west
}
