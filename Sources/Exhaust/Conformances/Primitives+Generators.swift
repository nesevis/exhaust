//
//  Primitives+Generators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//

// MARK: - Unsigned Integers

@_spi(ExhaustInternal) import ExhaustCore

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

// MARK: - AnyIndex

public extension AnyIndex {
    /// Returns a generator of `AnyForwardIndex` values.
    static var arbitrary: ReflectiveGenerator<AnyIndex> {
        Gen.choose(in: 0 ... Int.max).map(AnyIndex.init)
    }
}
