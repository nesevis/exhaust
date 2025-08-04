//
//  Primitives+Arbitrary.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//

// MARK: - Unsigned Integers

extension UInt64: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            // This needs a bit more work to slow the scaling down a tad. Counteract logarithm?
            let expanded: UInt64 = size < 64 ? 1 << size : UInt64.max
            return Gen.choose(in: UInt64.min...expanded)
        }
    }
}

extension UnsignedInteger {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        UInt64.arbitrary
            .mapped(forward: { Self(truncatingIfNeeded: $0) }, backward: { UInt64($0) })
    }
}

extension UInt: Arbitrary {}
extension UInt8: Arbitrary {}
extension UInt16: Arbitrary {}
extension UInt32: Arbitrary {}

// MARK: - Signed integers

extension Int64: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 63 ? 1 << size : UInt64(Int64.max)
            return Gen.choose(in: -Int64(expanded)...Int64(expanded))
        }
    }
}

// FIXME: Do we need this. Is reflection still broken here?
//extension Int16: Arbitrary {
//    static var arbitrary: ReflectiveGenerator<Any, Self> {
//        Gen.getSize().bind { size in
//            let expanded: UInt64 = size < 15 ? 1 << size : UInt64(Int16.max)
//            let truncated = abs(Int16(truncatingIfNeeded: expanded))
//            return Gen.choose(in: -truncated...truncated)
//        }
//    }
//}

extension SignedInteger {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Int64.arbitrary
            .mapped(forward: { Self(truncatingIfNeeded: $0) }, backward: { Int64($0) })
    }
}

extension Int: Arbitrary {}
extension Int8: Arbitrary {}
extension Int16: Arbitrary {}
extension Int32: Arbitrary {}

// MARK: - Floating points

extension Double: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            // TODO: use pow() to scale range
            let boundary = size == UInt64.max ? Double.greatestFiniteMagnitude : Double(size)
            return Gen.choose(in: -boundary...boundary)
        }
    }
}

extension BinaryFloatingPoint {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Double.arbitrary
            .mapped(forward: { Self($0) }, backward: { Double($0) })
    }
}

extension Float: Arbitrary {}

// MARK: - Boolean

extension Bool: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Bool> {
        Gen.pick(choices: [
            (1, Gen.just(true)),
            (1, Gen.just(false))
        ])
    }
}

// MARK: - Strings and Characters

extension Character: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Character> {
        Gen.getSize().bind { size in
            Gen.pick(choices: [
                (200, Gen.chooseCharacter(in: self.bitPatternRanges[0])), // Standard ascii
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[1])), // Control characters
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[2])), // First bit of unicode minus ascii
                (size / 2, Gen.chooseCharacter(in: self.bitPatternRanges[3])) // Second bit of unicode
            ])
        }
    }
}

extension String: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, String> {
        Gen.arrayOf(Character.arbitrary)
            .map { String($0) }
    }
}

// MARK: - Optional

extension Optional: Arbitrary where Wrapped: Arbitrary, Wrapped: Equatable {
    static var arbitrary: ReflectiveGenerator<Any, Optional<Wrapped>> {
        Gen.pick(choices: [
            (1, Gen.just(.none)),
            (5, Wrapped.arbitrary.map { .some($0) })
        ])
    }
}
