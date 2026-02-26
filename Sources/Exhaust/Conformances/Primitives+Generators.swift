//
//  Primitives+Generators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//

// MARK: - Unsigned Integers

extension UInt {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            // This needs a bit more work to slow the scaling down a tad. Counteract logarithm?
            let expanded: UInt = size < 64 ? 1 << size : UInt.max
            return Gen.chooseDerived(in: UInt.min ... expanded)
        }
    }
}

extension UInt64 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            // This needs a bit more work to slow the scaling down a tad. Counteract logarithm?
            let expanded: UInt64 = size < 64 ? 1 << size : UInt64.max
            return Gen.chooseDerived(in: UInt64.min ... expanded)
        }
    }
}

// MARK: - Signed integers

extension UInt8 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 7 ? 1 << size : UInt64(UInt8.max)
            return Gen.chooseDerived(in: 0 ... UInt8(expanded))
        }
    }
}

extension UInt16 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 15 ? 1 << size : UInt64(UInt16.max)
            return Gen.chooseDerived(in: 0 ... UInt16(expanded))
        }
    }
}

extension UInt32 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            let expanded: UInt64 = size < 31 ? 1 << size : UInt64(UInt32.max)
            return Gen.chooseDerived(in: 0 ... UInt32(expanded))
        }
    }
}

extension Int {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            if size < 63 {
                let expanded: UInt64 = 1 << size
                return Gen.chooseDerived(in: -Int(expanded) ... Int(expanded))
            }
            return Gen.chooseDerived(in: Int.min ... Int.max)
        }
    }
}

extension Int8 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            if size < 7 {
                let expanded: UInt64 = 1 << size
                return Gen.chooseDerived(in: -Int8(expanded) ... Int8(expanded))
            }
            return Gen.chooseDerived(in: Int8.min ... Int8.max)
        }
    }
}

extension Int16 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            if size < 15 {
                let expanded: UInt64 = 1 << size
                return Gen.chooseDerived(in: -Int16(expanded) ... Int16(expanded))
            }
            // TODO: Fix this elsewhere
            return Gen.chooseDerived(in: Int16.min ... Int16.max)
        }
    }
}

extension Int32 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            if size < 31 {
                let expanded: UInt64 = 1 << size
                return Gen.chooseDerived(in: -Int32(expanded) ... Int32(expanded))
            }
            return Gen.chooseDerived(in: Int32.min ... Int32.max)
        }
    }
}

extension Int64 {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            if size < 63 {
                let expanded: UInt64 = 1 << size
                return Gen.chooseDerived(in: -Int64(expanded) ... Int64(expanded))
            }
            return Gen.chooseDerived(in: Int64.min ... Int64.max)
        }
    }
}

// MARK: - Floating points

extension Double {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            // TODO: use pow() to scale range?
            let boundary = size == UInt64.max ? Double.greatestFiniteMagnitude : Double(size)
            return Gen.chooseDerived(in: -boundary ... boundary)
        }
    }
}

extension Float {
    public static var arbitrary: ReflectiveGenerator<Self> {
        Gen.getSize().bind { size in
            // TODO: use pow() to scale range
            let boundary = size == UInt64.max ? Float.greatestFiniteMagnitude : Float(size)
            return Gen.chooseDerived(in: -boundary ... boundary)
        }
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
