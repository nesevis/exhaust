//
//  ReflectiveGenerator+NumericGenerators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

public extension ReflectiveGenerator where Value == Double {
    static func double(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func double(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == Float {
    static func float(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func float(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == UInt8 {
    static func uint8(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func uint8(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == UInt16 {
    static func uint16(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func uint16(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == UInt32 {
    static func uint32(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func uint32(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == UInt64 {
    static func uint64(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func uint64(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == UInt {
    static func uint(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func uint(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == Int8 {
    static func int8(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func int8(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == Int16 {
    static func int16(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func int16(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == Int32 {
    static func int32(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func int32(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == Int64 {
    static func int64(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func int64(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}

public extension ReflectiveGenerator where Value == Int {
    static func int(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range)
    }

    static func int(in range: ClosedRange<Value>, scaling: SizeScaling<Value>) -> ReflectiveGenerator<Value> {
        Gen.choose(in: range, scaling: scaling)
    }
}
