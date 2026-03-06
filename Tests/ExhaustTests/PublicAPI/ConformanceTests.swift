//
//  ConformanceTests.swift
//  Exhaust
//

import Testing
@testable import Exhaust
import ExhaustCore

@Suite("Public API Conformances")
struct ConformanceTests {
    // MARK: - Collections

    @Suite("Collection conformances")
    struct Collections {
        // MARK: Static methods

        @Test("Static .array(gen) produces arrays")
        func staticArray() {
            let gen: ReflectiveGenerator<[Int]> = .array(Gen.choose(in: 0 ... 100))
            var iterator = ValueInterpreter(gen, seed: 42)

            if let array = iterator.next() {
                for element in array {
                    #expect(0 ... 100 ~= element)
                }
            }
        }

        @Test("Static .array(gen, length:) produces fixed-range arrays")
        func staticArrayWithLength() {
            let gen: ReflectiveGenerator<[Int]> = .array(
                Gen.choose(in: 0 ... 100),
                length: 3 ... 5
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let array = iterator.next() {
                #expect(array.count >= 3 && array.count <= 5)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Static .array(gen, length:) with linear scaling")
        func staticArrayLinear() {
            let gen: ReflectiveGenerator<[Int]> = .array(Gen.choose(in: 0 ... 10), length: 0 ... 10, scaling: .linear)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Static .array(gen, length:) with constant scaling")
        func staticArrayConstant() {
            let gen: ReflectiveGenerator<[Int]> = .array(Gen.choose(in: 0 ... 10), length: 0 ... 10, scaling: .constant)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Static .array(gen, length:) with exponential scaling")
        func staticArrayExponential() {
            let gen: ReflectiveGenerator<[Int]> = .array(Gen.choose(in: 0 ... 10), length: 0 ... 10, scaling: .exponential)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Static .set(gen) produces sets")
        func staticSet() {
            let gen: ReflectiveGenerator<Set<Int>> = .set(Gen.choose(in: 0 ... 1000))
            var iterator = ValueInterpreter(gen, seed: 42)

            if let set = iterator.next() {
                for element in set {
                    #expect(0 ... 1000 ~= element)
                }
            }
        }

        @Test("Static .set(gen, count:) produces bounded sets")
        func staticSetWithCount() {
            let gen: ReflectiveGenerator<Set<Int>> = .set(
                Gen.choose(in: 0 ... 1000),
                count: 2 ... 5,
                scaling: .constant
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let set = iterator.next() {
                #expect(set.count >= 2 && set.count <= 5)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Static .dictionary(k, v) produces dictionaries")
        func staticDictionary() {
            let gen: ReflectiveGenerator<[Int: Int]> = .dictionary(
                Gen.choose(in: 0 ... 100),
                Gen.choose(in: 0 ... 100)
            )
            var iterator = ValueInterpreter(gen, seed: 42)

            if let dict = iterator.next() {
                for (key, value) in dict {
                    #expect(0 ... 100 ~= key)
                    #expect(0 ... 100 ~= value)
                }
            }
        }

        @Test("Static .shuffled(gen) produces shuffled array")
        func staticShuffled() {
            let source = ReflectiveGenerator<[Int]>.pure([1, 2, 3, 4, 5])
            let gen: ReflectiveGenerator<[Int]> = .shuffled(source)
            var iterator = ValueInterpreter(gen, seed: 42)

            if let result = iterator.next() {
                #expect(result.sorted() == [1, 2, 3, 4, 5])
            }
        }

        // MARK: Instance methods

        @Test("Instance .array() produces arrays")
        func instanceArray() {
            let gen = (Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>).array()
            var iterator = ValueInterpreter(gen, seed: 42)

            if let array = iterator.next() {
                for element in array {
                    #expect(0 ... 100 ~= element)
                }
            }
        }

        @Test("Instance .array(length:scaling:) with linear scaling")
        func instanceArrayLinear() {
            let gen = (Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>).array(length: 0 ... 10, scaling: .linear)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Instance .array(length:scaling:) with constant scaling")
        func instanceArrayConstant() {
            let gen = (Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>).array(length: 0 ... 10, scaling: .constant)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Instance .array(length:scaling:) with exponential scaling")
        func instanceArrayExponential() {
            let gen = (Gen.choose(in: 0 ... 10) as ReflectiveGenerator<Int>).array(length: 0 ... 10, scaling: .exponential)
            var iterator = ValueInterpreter(gen, seed: 42)
            if let array = iterator.next() { #expect(array.count <= 10) }
        }

        @Test("Instance .set() produces sets")
        func instanceSet() {
            let gen = (Gen.choose(in: 0 ... 1000) as ReflectiveGenerator<Int>).set()
            var iterator = ValueInterpreter(gen, seed: 42)

            if let set = iterator.next() {
                for element in set {
                    #expect(0 ... 1000 ~= element)
                }
            }
        }

        @Test("Instance .set(count:) produces bounded sets")
        func instanceSetWithCount() {
            let gen = (Gen.choose(in: 0 ... 1000) as ReflectiveGenerator<Int>)
                .set(count: 2 ... 5, scaling: .constant)
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            while let set = iterator.next() {
                #expect(set.count >= 2 && set.count <= 5)
                generated += 1
            }
            #expect(generated > 0)
        }

        @Test("Instance .shuffled() produces shuffled collection")
        func instanceShuffled() {
            let gen = (ReflectiveGenerator<[Int]>.pure([1, 2, 3, 4, 5])).shuffled()
            var iterator = ValueInterpreter(gen, seed: 42)

            if let result = iterator.next() {
                #expect(result.sorted() == [1, 2, 3, 4, 5])
            }
        }

        @Test("Instance .element() on Hashable collection")
        func instanceElementHashable() {
            let gen = (Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>)
                .array(length: 5)
                .bind { array in
                    Gen.element(from: array).map { element in
                        (array, element)
                    }
                }
            var iterator = ValueInterpreter(gen, seed: 42)

            if let (array, element) = iterator.next() {
                #expect(array.contains(element))
            }
        }
    }

    // MARK: - Numeric generators

    @Suite("Numeric conformances")
    struct Numerics {
        // MARK: Double

        @Test("double() produces doubles")
        func doubleDefault() {
            let gen: ReflectiveGenerator<Double> = .double()
            var iterator = ValueInterpreter(gen, seed: 42)
            #expect(iterator.next() != nil)
        }

        @Test("double(in:) with explicit range")
        func doubleInRange() {
            let gen: ReflectiveGenerator<Double> = .double(in: 0.0 ... 1.0)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = iterator.next() {
                    #expect(0.0 ... 1.0 ~= value)
                }
            }
        }

        @Test("double(in:scaling:) with explicit scaling")
        func doubleWithScaling() {
            let gen: ReflectiveGenerator<Double> = .double(in: -10.0 ... 10.0, scaling: .constant)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = iterator.next() {
                    #expect(-10.0 ... 10.0 ~= value)
                }
            }
        }

        // MARK: Float

        @Test("float() produces floats")
        func floatDefault() {
            let gen: ReflectiveGenerator<Float> = .float()
            var iterator = ValueInterpreter(gen, seed: 42)
            #expect(iterator.next() != nil)
        }

        @Test("float(in:) with Float range")
        func floatInRange() {
            let gen: ReflectiveGenerator<Float> = .float(in: Float(0.0) ... Float(1.0))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = iterator.next() {
                    #expect(Float(0.0) ... Float(1.0) ~= value)
                }
            }
        }

        @Test("float(in:) with Double range convenience")
        func floatInDoubleRange() {
            let gen: ReflectiveGenerator<Float> = .float(in: 0.0 ... 1.0)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let value = iterator.next() {
                    #expect(Float(0.0) ... Float(1.0) ~= value)
                }
            }
        }

        // MARK: Signed integers

        @Test("int8() with and without range")
        func int8Gen() {
            let gen1: ReflectiveGenerator<Int8> = .int8()
            let gen2: ReflectiveGenerator<Int8> = .int8(in: -10 ... 10)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(-10 ... 10 ~= v)
            }
        }

        @Test("int16() with and without range")
        func int16Gen() {
            let gen1: ReflectiveGenerator<Int16> = .int16()
            let gen2: ReflectiveGenerator<Int16> = .int16(in: -100 ... 100)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(-100 ... 100 ~= v)
            }
        }

        @Test("int32() with and without range")
        func int32Gen() {
            let gen1: ReflectiveGenerator<Int32> = .int32()
            let gen2: ReflectiveGenerator<Int32> = .int32(in: -1000 ... 1000)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(-1000 ... 1000 ~= v)
            }
        }

        @Test("int64() with and without range")
        func int64Gen() {
            let gen1: ReflectiveGenerator<Int64> = .int64()
            let gen2: ReflectiveGenerator<Int64> = .int64(in: -1000 ... 1000)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(-1000 ... 1000 ~= v)
            }
        }

        @Test("int() with and without range")
        func intGen() {
            let gen1: ReflectiveGenerator<Int> = .int()
            let gen2: ReflectiveGenerator<Int> = .int(in: -1000 ... 1000)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(-1000 ... 1000 ~= v)
            }
        }

        // MARK: Unsigned integers

        @Test("uint8() with and without range")
        func uint8Gen() {
            let gen1: ReflectiveGenerator<UInt8> = .uint8()
            let gen2: ReflectiveGenerator<UInt8> = .uint8(in: 0 ... 50)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(0 ... 50 ~= v)
            }
        }

        @Test("uint16() with and without range")
        func uint16Gen() {
            let gen1: ReflectiveGenerator<UInt16> = .uint16()
            let gen2: ReflectiveGenerator<UInt16> = .uint16(in: 0 ... 500)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(0 ... 500 ~= v)
            }
        }

        @Test("uint32() with and without range")
        func uint32Gen() {
            let gen1: ReflectiveGenerator<UInt32> = .uint32()
            let gen2: ReflectiveGenerator<UInt32> = .uint32(in: 0 ... 5000)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(0 ... 5000 ~= v)
            }
        }

        @Test("uint64() with and without range")
        func uint64Gen() {
            let gen1: ReflectiveGenerator<UInt64> = .uint64()
            let gen2: ReflectiveGenerator<UInt64> = .uint64(in: 0 ... 10000)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(0 ... 10000 ~= v)
            }
        }

        @Test("uint() with and without range")
        func uintGen() {
            let gen1: ReflectiveGenerator<UInt> = .uint()
            let gen2: ReflectiveGenerator<UInt> = .uint(in: 0 ... 10000)
            var iter1 = ValueInterpreter(gen1, seed: 42)
            var iter2 = ValueInterpreter(gen2, seed: 42)

            #expect(iter1.next() != nil)
            if let v = iter2.next() {
                #expect(0 ... 10000 ~= v)
            }
        }
    }

    // MARK: - Miscellaneous

    @Suite("Miscellaneous conformances")
    struct Miscellaneous {
        @Test("bool() produces both true and false")
        func boolBothValues() {
            let gen: ReflectiveGenerator<Bool> = .bool()
            var sawTrue = false
            var sawFalse = false

            for seed in UInt64(1) ... 20 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = iterator.next() {
                    if value { sawTrue = true } else { sawFalse = true }
                }
                if sawTrue && sawFalse { break }
            }

            #expect(sawTrue, "Expected at least one true")
            #expect(sawFalse, "Expected at least one false")
        }

        @Test("Instance .optional() produces both nil and non-nil")
        func instanceOptional() {
            let gen = (Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>).optional()
            var sawNil = false
            var sawSome = false

            for seed in UInt64(1) ... 50 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = iterator.next() {
                    if value == nil { sawNil = true } else { sawSome = true }
                }
                if sawNil && sawSome { break }
            }

            #expect(sawNil, "Expected at least one nil")
            #expect(sawSome, "Expected at least one non-nil")
        }

        @Test("oneOf for CaseIterable produces all cases")
        func oneOfCaseIterable() {
            let gen: ReflectiveGenerator<ConformanceDirection> = .oneOf(ConformanceDirection.self)
            var seen: Set<String> = []

            for seed in UInt64(1) ... 50 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = iterator.next() {
                    seen.insert("\(value)")
                }
                if seen.count == 4 { break }
            }

            #expect(seen.count == 4, "Expected all 4 directions, got \(seen)")
        }

        @Test(".just() produces constant value")
        func justConstant() {
            let gen: ReflectiveGenerator<Int> = .just(42)
            var iterator = ValueInterpreter(gen, seed: 1)
            #expect(iterator.next() == 42)
        }

        @Test("oneOf(generators...) picks from generators")
        func oneOfGenerators() {
            let gen: ReflectiveGenerator<Int> = .oneOf(
                Gen.choose(in: 0 ... 0),
                Gen.choose(in: 100 ... 100)
            )
            var sawZero = false
            var sawHundred = false

            for seed in UInt64(1) ... 50 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = iterator.next() {
                    if value == 0 { sawZero = true }
                    if value == 100 { sawHundred = true }
                }
                if sawZero && sawHundred { break }
            }

            #expect(sawZero, "Expected to see 0")
            #expect(sawHundred, "Expected to see 100")
        }

        @Test("oneOf(weighted:) respects weights")
        func oneOfWeighted() {
            let gen: ReflectiveGenerator<Int> = .oneOf(
                weighted: (100, Gen.choose(in: 0 ... 0)),
                (1, Gen.choose(in: 100 ... 100))
            )

            var counts = [0: 0, 100: 0]
            for seed in UInt64(1) ... 200 {
                var iterator = ValueInterpreter(gen, seed: seed)
                if let value = iterator.next() {
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
