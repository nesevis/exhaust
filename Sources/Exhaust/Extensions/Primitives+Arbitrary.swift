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
}

extension UInt16: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt16> {
        Gen.choose(in: UInt16.min...UInt16.max)
    }
}

extension UInt32: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt32> {
        Gen.choose(in: UInt32.min...UInt32.max)
    }
}

extension UInt64: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt64> {
        Gen.choose(in: UInt64.min...UInt64.max)
    }
}

extension UInt: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, UInt> {
        Gen.choose(in: UInt.min...UInt.max)
    }
}

extension Int: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.choose(in: Int.min...Int.max)
    }
}

extension Float: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Float> {
        Gen.choose(in: -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude)
    }
}

extension Double: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Double> {
        Gen.choose(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
    }
}

extension Unicode.Scalar: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Unicode.Scalar> {
        Gen.choose(in: self.bitPatternRange)
            .map { Unicode.Scalar(UInt32($0))! }
    }
}

extension Character: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Character> {
        Unicode.Scalar.arbitrary
            .map { Character($0) }
    }
}

extension String: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, String> {
        Gen.arrayOf(Character.arbitrary, Gen.choose(in: 0...10))
            .map { String($0) }
    }
}
