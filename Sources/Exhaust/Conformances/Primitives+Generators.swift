//
//  Primitives+Generators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//

// MARK: - Unsigned Integers

extension UInt {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension UInt64 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension UInt8 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension UInt16 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension UInt32 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

// MARK: - Signed integers

extension Int {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension Int8 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension Int16 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension Int32 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

extension Int64 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: Self.defaultScaling)
    }
}

// MARK: - Floating points

extension Double {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(
            in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude,
            scaling: Self.defaultScaling,
        )
    }
}

extension Float {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(
            in: -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude,
            scaling: Self.defaultScaling,
        )
    }
}

// MARK: - Boolean

extension Bool {
    public static var arbitrary: ReflectiveGenerator<Bool> {
        Gen.pick(choices: [
            (1, Gen.just(true)),
            (1, Gen.just(false)),
        ])
    }
}

// MARK: - Strings and Characters

extension Character {
    public static var arbitrary: ReflectiveGenerator<Character> {
        // This is nearly ten times slower than `arbitraryAscii`.
        Gen.getSize().bind { size in
            Gen.pick(choices: [
                (200, Gen.chooseCharacter(in: self.bitPatternRanges[0])), // Standard ascii
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[1])), // Control characters
                (size, Gen.chooseCharacter(in: self.bitPatternRanges[2])), // First bit of unicode minus ascii
                (size / 2, Gen.chooseCharacter(in: self.bitPatternRanges[3])), // Second bit of unicode
            ])
        }
    }

    // We need to use `chooseCharacter`, as the Character constructor isn't bijective with UInt32
    // FIXME: Does SwiftCheck handle this in any way?
    static var arbitraryAscii: ReflectiveGenerator<Character> {
        Gen.chooseCharacter(in: bitPatternRanges[0])
    }
}

extension String {
    public static var arbitrary: ReflectiveGenerator<String> {
        Gen.arrayOf(Character.arbitrary)
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }

    public static var arbitraryAscii: ReflectiveGenerator<String> {
        Gen.arrayOf(Character.arbitraryAscii)
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }
}

// MARK: - AnyIndex

extension AnyIndex {
    /// Returns a generator of `AnyForwardIndex` values.
    public static var arbitrary: ReflectiveGenerator<AnyIndex> {
        Gen.choose(in: 0 ... Int.max).map(AnyIndex.init)
    }
}
