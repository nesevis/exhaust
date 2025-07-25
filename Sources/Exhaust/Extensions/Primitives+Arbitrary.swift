//
//  Primitives+Arbitrary.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//

extension Bool: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Bool> {
        Gen.pick(choices: [
            (1, Gen.just(true)),
            (1, Gen.just(false))
        ])
    }
}

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

extension Int8: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int8> {
        Gen.choose(in: Int8.min...Int8.max)
    }
}

extension Int16: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int16> {
        Gen.choose(in: Int16.min...Int16.max)
    }
}

extension Int32: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int32> {
        Gen.choose(in: Int32.min...Int32.max)
    }
}

extension Int64: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Int64> {
        Gen.choose(in: Int64.min...Int64.max)
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
        Gen.pick(choices: [
            (10, Gen.choose(in: self.bitPatternRanges[0])),
//            (1, Gen.choose(in: self.bitPatternRanges[1])),
        ])
        .map { Unicode.Scalar(UInt32($0))! }
    }
}

extension Character: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Character> {
        Gen.chooseCharacter()
    }
}

extension String: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, String> {
        Gen.arrayOf(Character.arbitrary, Gen.choose(in: 0...150))
            .map { String($0) }
    }
}

extension Optional: Arbitrary where Wrapped: Arbitrary, Wrapped: Equatable {
    static var arbitrary: ReflectiveGenerator<Any, Optional<Wrapped>> {
        Gen.pick(choices: [
            (1, Gen.just(.none)),
            (5, Wrapped.arbitrary.bind { Gen.just($0) })
        ])
    }
}
