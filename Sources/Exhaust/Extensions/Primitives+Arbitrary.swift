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

// MARK: - Signed integers

extension UInt: Arbitrary {}
extension UInt8: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 7 ? 1 << size : UInt64(UInt8.max)
            return Gen.choose(in: 0...UInt8(expanded))
        }
    }
}
extension UInt16: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 15 ? 1 << size : UInt64(UInt16.max)
            return Gen.choose(in: 0...UInt16(expanded))
        }
    }
}
extension UInt32: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 31 ? 1 << size : UInt64(UInt32.max)
            return Gen.choose(in: 0...UInt32(expanded))
        }
    }
}

extension SignedInteger {
    // TODO: Implement individually. The ranges are all messed up
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Int64.arbitrary
            .mapped(forward: { Self(truncatingIfNeeded: $0) }, backward: { Int64($0) })
    }
}

extension Int: Arbitrary {}
extension Int8: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 7 ? 1 << size : UInt64(Int8.max)
            return Gen.choose(in: -Int8(expanded)...Int8(expanded))
        }
    }
}
extension Int16: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 15 ? 1 << size : UInt64(Int16.max)
            return Gen.choose(in: -Int16(expanded)...Int16(expanded))
        }
    }
}
extension Int32: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 31 ? 1 << size : UInt64(Int32.max)
            return Gen.choose(in: -Int32(expanded)...Int32(expanded))
        }
    }
}

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
        // This is nearly ten times slower than `arbitraryAscii`.
        Gen.getSize().bind { size in
            Gen.pick(choices: [
                (200, Gen.chooseCharacter(in: self.bitPatternRanges[0])), // Standard ascii
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[1])), // Control characters
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[2])), // First bit of unicode minus ascii
                (size / 2, Gen.chooseCharacter(in: self.bitPatternRanges[3])) // Second bit of unicode
            ])
        }
    }
    
    // We need to use `chooseCharacter`, as the Character constructor isn't bijective with UInt32
    // FIXME: Does SwiftCheck handle this in any way?
    static var arbitraryAscii: ReflectiveGenerator<Any, Character> {
        Gen.chooseCharacter(in: self.bitPatternRanges[0])
    }
}

extension String: Arbitrary {
    static var arbitrary: ReflectiveGenerator<Any, String> {
        Gen.arrayOf(Character.arbitrary)
            .map { String($0) }
    }
    
    static var arbitraryAscii: ReflectiveGenerator<Any, String> {
        Gen.arrayOf(Character.arbitraryAscii)
            .mapped(forward: { String($0) }, backward: { Array($0) })
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
