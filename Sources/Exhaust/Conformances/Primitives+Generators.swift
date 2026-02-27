//
//  Primitives+Generators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//

// MARK: - Unsigned Integers

import ExhaustCore

public extension UInt {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension UInt64 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension UInt8 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension UInt16 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension UInt32 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

// MARK: - Signed integers

public extension Int {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension Int8 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension Int16 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension Int32 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

public extension Int64 {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(in: Self.min ... Self.max, scaling: defaultScaling)
    }
}

// MARK: - Floating points

public extension Double {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(
            in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude,
            scaling: defaultScaling,
        )
    }
}

public extension Float {
    static var arbitrary: ReflectiveGenerator<Self> {
        Gen.choose(
            in: -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude,
            scaling: defaultScaling,
        )
    }
}

// MARK: - Boolean

public extension Bool {
    static var arbitrary: ReflectiveGenerator<Bool> {
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

public extension String {
    static var arbitrary: ReflectiveGenerator<String> {
        Gen.arrayOf(Character.arbitrary)
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }

    static var arbitraryAscii: ReflectiveGenerator<String> {
        Gen.arrayOf(Character.arbitraryAscii)
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }
}

// MARK: - AnyIndex

public extension AnyIndex {
    /// Returns a generator of `AnyForwardIndex` values.
    static var arbitrary: ReflectiveGenerator<AnyIndex> {
        Gen.choose(in: 0 ... Int.max).map(AnyIndex.init)
    }
}
