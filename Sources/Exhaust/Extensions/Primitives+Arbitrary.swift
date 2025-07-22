//
//  Primitives+Arbitrary.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//

extension UInt8: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt8> {
        Gen.choose(in: UInt8.min...UInt8.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.unsignedIntegers }
}

extension UInt16: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt16> {
        Gen.choose(in: UInt16.min...UInt16.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.unsignedIntegers }
}

extension UInt32: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt32> {
        Gen.choose(in: UInt32.min...UInt32.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.unsignedIntegers }
}

extension UInt64: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt64> {
        Gen.choose(in: UInt64.min...UInt64.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.unsignedIntegers }
}

extension UInt: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt> {
        Gen.choose(in: UInt.min...UInt.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.unsignedIntegers }
}

extension Int8: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int8> {
        Gen.choose(in: Int8.min...Int8.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.signedIntegers }
}

extension Int16: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int16> {
        Gen.choose(in: Int16.min...Int16.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.signedIntegers }
}

extension Int32: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int32> {
        Gen.choose(in: Int32.min...Int32.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.signedIntegers }
}

extension Int64: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int64> {
        Gen.choose(in: Int64.min...Int64.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.signedIntegers }
}

extension Int: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.choose(in: Int.min...Int.max)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.signedIntegers }
}

extension Float: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Float> {
        Gen.choose(in: -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.floatingPoints }
}

extension Double: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Double> {
        Gen.choose(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.floatingPoints }
}

extension Unicode.Scalar: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Unicode.Scalar> {
        Gen.pick(choices: [
            (10, Gen.choose(in: self.bitPatternRanges[0])),
//            (1, Gen.choose(in: self.bitPatternRanges[1])),
        ])
        .map { Unicode.Scalar(UInt32($0))! }
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.characters }
}

extension Character: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Character> {
        Gen.chooseCharacter()
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.characters }
}

extension String: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, String> {
        Gen.arrayOf(Character.arbitrary, Gen.choose(in: 0...150))
            .map { String($0) }
    }
    static var strategies: [ShrinkingStrategy] { ShrinkingStrategy.sequences }
}

extension Optional: Arbitrary where Wrapped: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Optional<Wrapped>> {
        Gen.pick(choices: [
            (1, Gen.just(.none)),
            (5, Wrapped.arbitrary.map { .some($0) })
        ])
    }
    static var strategies: [ShrinkingStrategy] { Wrapped.strategies }
}
