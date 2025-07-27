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
        Gen.getSize().bind { size in
            Gen.choose(in: UInt64.min...size)
        }
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
        Gen.getSize().bind { size in
            Gen.choose(in: -Int(size)...Int(size))
        }
    }
}

extension Float: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Float> {
        Gen.choose(in: -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude)
    }
}

extension Double: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Double> {
        Gen.getSize().bind { size in
            Gen.choose(in: -Double(size)...Double(size))
        }
//        Gen.choose(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
    }
}

extension Unicode.Scalar: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Unicode.Scalar> {
        Gen.getSize().bind { size in
            Gen.pick(choices: [
                (200, Gen.choose(in: 32...126)), // Standard ascii
                (size, Gen.choose(in: self.bitPatternRanges[0])),
                ((size + 2) / 2, Gen.choose(in: self.bitPatternRanges[1]))
            ])
        }
        .mapped(
            forward: { Unicode.Scalar(UInt32($0))! },
            backward: { UInt64($0) }
        )
    }
}

extension Character: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Character> {
        Gen.getSize().bind { size in
            Gen.pick(choices: [
                (200, Gen.chooseCharacter(in: self.bitPatternRanges[0])), // Standard ascii
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[1])), // Null bytes, tab characters
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[2])),
                ((size + 2) / 2, Gen.chooseCharacter(in: self.bitPatternRanges[3]))
            ])
        }
//        .mapped(
//            forward: { $0 },
//            backward: { $0.unicodeScalars.max(by: { $0.bitPattern64 < $1.bitPattern64 })! }
//        )
    }
}

extension String: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, String> {
        Gen.arrayOf(Character.arbitrary)
            .map { String($0) }
    }
}

extension Optional: Arbitrary where Wrapped: Arbitrary, Wrapped: Equatable {
    static var arbitrary: ReflectiveGenerator<Any, Optional<Wrapped>> {
        Gen.pick(choices: [
            (1, Gen.just(.none)),
            (5, Wrapped.arbitrary.map { .some($0) })
        ])
    }
}
